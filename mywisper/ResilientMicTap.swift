//
//  ResilientMicTap.swift
//  mywisper
//
//  One microphone tap on a long-lived AVAudioEngine that survives audio-device changes.
//
//  Why this exists: connecting headphones (AirPods especially — they flip from 48 kHz A2DP
//  to 16/24 kHz HFP the moment their mic opens) changes the input hardware under a running
//  or idle engine. AVAudioEngine then (a) silently STOPS mid-session, so dictation hangs
//  with no audio, and (b) keeps a stale input format, so the next `installTap` raises an
//  Objective-C exception ("format.sampleRate == hwFormat.sampleRate") that Swift cannot
//  catch — the app crashes instantly.
//
//  This type:
//   • pins the engine's input unit to the chosen device (instead of flipping the SYSTEM
//     default input, which was global, racy, and itself triggered reconfigurations);
//   • reads the format from the hardware at every (re)start and builds a fresh tap handler
//     (and thus a fresh AVAudioConverter) for it;
//   • turns AVAudioEngine's NSExceptions into Swift errors instead of crashes;
//   • watches AVAudioEngineConfigurationChange + CoreAudio device-list / default-input
//     changes and transparently re-arms the tap, so a recording continues across a
//     headphone plug/unplug.
//

import AVFoundation
import AudioToolbox
import CoreAudio

enum MicTapError: Error, LocalizedError {
    case noInputDevice
    case engineException(String)

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone is available."
        case .engineException(let reason):
            return "Audio engine error: \(reason)"
        }
    }
}

final class ResilientMicTap: @unchecked Sendable {
    /// Builds the per-buffer handler for a given hardware format. Called on every (re)start,
    /// so anything format-dependent (converters, ratios) must be created inside it.
    typealias HandlerFactory = (AVAudioFormat) throws -> (AVAudioPCMBuffer) -> Void

    private let engine: AVAudioEngine
    private let bufferSize: AVAudioFrameCount
    private let label: String

    /// Serializes start / stop / restart. Never taken on the audio thread.
    private let control = NSLock()
    private let restartQueue: DispatchQueue

    private var running = false
    private var factory: HandlerFactory?
    private var onFailure: ((String) -> Void)?
    private var restartPending = false
    private var restartCount = 0
    private var engineObserver: NSObjectProtocol?
    private var hardwareListener: AudioObjectPropertyListenerBlock?

    /// Device changes can come in bursts (BT profile flip, aggregate rebuilds). Coalesce
    /// them and give the HAL a moment to settle before reading formats again.
    private static let restartDelay: TimeInterval = 0.3
    /// Safety valve: a device that keeps flapping must not spin us forever.
    private static let maxRestartsPerSession = 12

    init(engine: AVAudioEngine, bufferSize: AVAudioFrameCount, label: String) {
        self.engine = engine
        self.bufferSize = bufferSize
        self.label = label
        self.restartQueue = DispatchQueue(label: "com.barssoft.mywisper.mictap.\(label)")
    }

    deinit {
        removeObservers()
    }

    var isRunning: Bool {
        control.lock()
        defer { control.unlock() }
        return running
    }

    /// Arm the tap and start the engine. Throws (never crashes) if the microphone can't start.
    /// `onFailure` fires at most once if the tap dies later and cannot be recovered.
    func start(onFailure: ((String) -> Void)? = nil, makeHandler: @escaping HandlerFactory) throws {
        control.lock()
        defer { control.unlock() }

        if running { stopLocked() }
        factory = makeHandler
        self.onFailure = onFailure
        restartCount = 0
        restartPending = false

        try armLocked()
        running = true
        installObservers()
    }

    /// Stop capture and remove the tap. Safe to call repeatedly, from any thread. A no-op
    /// when this tap isn't running, so a stale owner can never tear down a newer session
    /// that shares the same engine.
    func stop() {
        control.lock()
        defer { control.unlock() }
        guard running else { return }
        stopLocked()
    }

    // MARK: - Arming

    private func stopLocked() {
        running = false
        factory = nil
        onFailure = nil
        removeObservers()
        teardownEngineLocked()
    }

    private func teardownEngineLocked() {
        _ = try? Self.catching {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
    }

    /// (Re)build the whole tap from the current hardware state.
    private func armLocked() throws {
        teardownEngineLocked()
        pinInputDeviceLocked()

        do {
            try installTapAndStartLocked()
        } catch {
            // The engine's cached graph can lag the hardware right after a device switch.
            // Reset it and try once more before giving up.
            DebugLog.log("mic[\(label)]: arm failed (\(error.localizedDescription)) — resetting engine, retrying")
            teardownEngineLocked()
            _ = try? Self.catching { engine.reset() }
            pinInputDeviceLocked()
            try installTapAndStartLocked()
        }
    }

    private func installTapAndStartLocked() throws {
        guard let factory else { throw MicTapError.noInputDevice }
        let input = engine.inputNode

        // Hardware format first: the tap MUST match the device's sample rate or AVAudioEngine
        // raises an exception. The bus output format is preferred when it agrees with it.
        let hardware = input.inputFormat(forBus: 0)
        let bus = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw MicTapError.noInputDevice
        }
        let tapFormat = (bus.sampleRate == hardware.sampleRate && bus.channelCount > 0) ? bus : hardware

        let handler = try factory(tapFormat)
        try Self.catching {
            input.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) { buffer, _ in
                handler(buffer)
            }
        }

        engine.prepare()
        var startError: Error?
        do {
            try Self.catching {
                do { try engine.start() } catch { startError = error }
            }
        } catch {
            startError = error
        }
        if let startError {
            _ = try? Self.catching { input.removeTap(onBus: 0) }
            throw startError
        }

        DebugLog.log("mic[\(label)]: armed \(Int(tapFormat.sampleRate)) Hz × \(tapFormat.channelCount) ch, device=\(currentUnitDevice() ?? 0)")
    }

    // MARK: - Device pinning

    /// The device we want to record from: the user's pick if still present, else the
    /// current system default input.
    private func desiredDeviceID() -> AudioDeviceID? {
        let savedID = SettingsManager.shared.selectedInputDeviceID
        if !savedID.isEmpty,
           let picked = AudioInputDevices.available().first(where: { $0.uniqueID == savedID }) {
            return picked.coreAudioID
        }
        return AudioInputDevices.currentDefaultInputDeviceID()
    }

    /// Point the engine's input unit at the desired device. Only ever done while stopped.
    private func pinInputDeviceLocked() {
        guard let target = desiredDeviceID(), target != 0 else { return }
        guard currentUnitDevice() != target else { return }
        guard let unit = engine.inputNode.audioUnit else { return }
        var device = target
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            DebugLog.log("mic[\(label)]: could not pin input device \(target) (status \(status)) — using engine default")
        }
    }

    private func currentUnitDevice() -> AudioDeviceID? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            &size
        )
        return status == noErr ? device : nil
    }

    // MARK: - Change observation

    private func installObservers() {
        removeObservers()

        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleRestart(reason: "engine configuration change")
        }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRestart(reason: "audio device change")
        }
        hardwareListener = listener
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = Self.systemAddress(selector)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, restartQueue, listener
            )
        }
    }

    private func removeObservers() {
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
            self.engineObserver = nil
        }
        if let hardwareListener {
            for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
                var address = Self.systemAddress(selector)
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, restartQueue, hardwareListener
                )
            }
            self.hardwareListener = nil
        }
    }

    private func scheduleRestart(reason: String) {
        control.lock()
        guard running, !restartPending else {
            control.unlock()
            return
        }
        restartPending = true
        control.unlock()

        DebugLog.log("mic[\(label)]: \(reason) — re-arming in \(Self.restartDelay)s")
        restartQueue.asyncAfter(deadline: .now() + Self.restartDelay) { [weak self] in
            self?.performRestart()
        }
    }

    private func performRestart() {
        control.lock()
        restartPending = false
        guard running else {
            control.unlock()
            return
        }

        // An unrelated device appeared/vanished and we're still recording from the right
        // one: leave the audio alone instead of punching a gap into it.
        if engine.isRunning, let desired = desiredDeviceID(), desired == currentUnitDevice() {
            control.unlock()
            return
        }

        restartCount += 1
        var failure: String?
        if restartCount > Self.maxRestartsPerSession {
            failure = "The audio device keeps changing — recording stopped."
        } else {
            do {
                try armLocked()
                DebugLog.log("mic[\(label)]: re-armed after device change (#\(restartCount))")
            } catch {
                failure = "Microphone lost after an audio device change: \(error.localizedDescription)"
            }
        }

        var callback: ((String) -> Void)?
        if let failure {
            DebugLog.log("mic[\(label)]: \(failure)")
            callback = onFailure
            stopLocked()
        }
        control.unlock()

        if let failure { callback?(failure) }
    }

    // MARK: - Helpers

    private static func systemAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Run `block`, converting an Objective-C exception into a thrown Swift error.
    private static func catching(_ block: () -> Void) throws {
        do {
            try ObjCExceptionCatcher.catchException(block)
        } catch {
            throw MicTapError.engineException(error.localizedDescription)
        }
    }
}

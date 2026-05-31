//
//  AudioRecorder.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import AVFoundation
import CoreAudio

class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var tempFileURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mywisper_recording.wav")
    }

    /// When we switch the system default input device to honor the user's chosen microphone,
    /// we stash the previous default here so `stopRecordingAndGetURL()` can restore it.
    private var previousDefaultInputDeviceID: AudioDeviceID?

    /// Current audio level (0.0 to 1.0), updated ~30 times per second
    var onAudioLevel: ((Float) -> Void)?

    /// Minimum recording length; anything shorter is discarded as an accidental tap.
    static let minimumDuration: TimeInterval = 0.3

    /// True when the most recent `stopRecordingAndGetURL()` returned nil specifically because
    /// the recording was shorter than `minimumDuration` (as opposed to no recorder at all).
    private(set) var lastRecordingWasTooShort = false

    func startRecording() throws {
        try? FileManager.default.removeItem(at: tempFileURL)

        // Honor the user's chosen input device. AVAudioRecorder always records from the system
        // default input, so temporarily switch the default to the selected device (restored on
        // stop). Falls back to the current default if the saved device is gone.
        applySelectedInputDevice()

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let rec = try AVAudioRecorder(url: tempFileURL, settings: settings)
        rec.isMeteringEnabled = true
        rec.prepareToRecord()

        guard rec.record() else {
            throw AudioRecorderError.recordingFailed
        }

        self.recorder = rec

        // Start metering timer for audio level visualization
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self, let rec = self.recorder else { return }
            rec.updateMeters()
            let dB = rec.averagePower(forChannel: 0) // -160 to 0
            // Normalize: -50 dB → 0.0, 0 dB → 1.0
            let normalized = max(0, min(1, (dB + 50) / 50))
            self.onAudioLevel?(normalized)
        }
    }

    /// Switch the system default input device to the user's chosen microphone, if one is set
    /// and still present. Stashes the previous default in `previousDefaultInputDeviceID` so we
    /// can restore it when recording stops. No-op (uses default) when "" / device missing.
    private func applySelectedInputDevice() {
        previousDefaultInputDeviceID = nil
        let savedID = SettingsManager.shared.selectedInputDeviceID
        guard !savedID.isEmpty else { return }

        guard let target = AudioInputDevices.available().first(where: { $0.uniqueID == savedID }) else {
            // Saved device is gone — fall back to system default silently.
            return
        }
        if let current = AudioInputDevices.currentDefaultInputDeviceID(), current != target.coreAudioID {
            previousDefaultInputDeviceID = current
            AudioInputDevices.setDefaultInputDevice(target.coreAudioID)
        }
    }

    /// Restore the system default input device we changed in `applySelectedInputDevice()`.
    private func restoreDefaultInputDevice() {
        if let previous = previousDefaultInputDeviceID {
            AudioInputDevices.setDefaultInputDevice(previous)
            previousDefaultInputDeviceID = nil
        }
    }

    /// Stop recording and return the audio file URL
    func stopRecordingAndGetURL() -> URL? {
        meterTimer?.invalidate()
        meterTimer = nil
        onAudioLevel?(0)
        lastRecordingWasTooShort = false
        restoreDefaultInputDevice()

        guard let rec = recorder else { return nil }

        let duration = rec.currentTime
        rec.stop()
        self.recorder = nil

        guard duration > Self.minimumDuration else {
            lastRecordingWasTooShort = true
            return nil
        }

        return tempFileURL
    }
}

enum AudioRecorderError: Error, LocalizedError {
    case invalidFormat
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Invalid audio input format."
        case .recordingFailed:
            return "Failed to start recording."
        }
    }
}

//
//  FastSpeechService.swift
//  mywisper
//
//  Streaming on-device transcription via Apple's SpeechAnalyzer / SpeechTranscriber
//  (new in macOS 26 Tahoe). Unlike the batch engines, this transcribes WHILE the user
//  speaks, so the final text is ready almost the instant recording stops.
//
//  Speed comes from two things:
//    1. Streaming: audio is fed to the analyzer live; stop only finalizes the tail.
//    2. Prewarming: a prepared analyzer (model loaded, `prepareToAnalyze` done) is kept
//       per selected language and rebuilt in the background after every session, so the
//       hotkey press spends zero time on model setup.
//
//  NOTE: Apple's new API supports fewer languages than SFSpeechRecognizer (no Russian as
//  of macOS 26.5). `supportedLanguageCodes()` is the authoritative gate — the older
//  `supportedLocale(equivalentTo:)` misleadingly "resolves" unsupported locales, and the
//  asset download then fails. DictationManager falls back to the classic Apple engine
//  whenever the selected language is not in this set.
//

import Foundation
import AVFoundation
import Accelerate
import CoreAudio
import Speech

// Names are qualified as `Speech.SpeechTranscriber` throughout because the app has its own
// legacy `SpeechTranscriber` class (SFSpeechRecognizer wrapper) that shadows Apple's type.

@available(macOS 26.0, *)
actor FastSpeechService {

    enum FastSpeechError: LocalizedError {
        case unavailable
        case unsupportedLanguage
        case missingAudioFormat
        case sessionAlreadyActive
        case noActiveSession
        case microphoneUnavailable

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Apple Live transcription is unavailable on this Mac."
            case .unsupportedLanguage:
                return "The selected language is not supported by Apple Live transcription."
            case .missingAudioFormat:
                return "Apple Live transcription did not provide a compatible audio format."
            case .sessionAlreadyActive:
                return "A dictation session is already active."
            case .noActiveSession:
                return "No dictation session is active."
            case .microphoneUnavailable:
                return "No microphone input is available."
            }
        }
    }

    /// A finished session's transcript plus its average per-word confidence (0…1), or nil
    /// when the API reported none. The dual-language race compares this against the other
    /// recognizer's score — a transcriber fed the wrong language scores dramatically lower
    /// (measured here: right language ≈ 0.9+, wrong language ≈ 0.05–0.3).
    struct FastResult: Sendable {
        let text: String
        let confidence: Double?
    }

    private struct PreparedSession {
        let locale: Locale
        let transcriber: Speech.SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let audioFormat: AVAudioFormat
    }

    private struct ActiveSession {
        /// Monotonic token identifying THIS session; a stale early-kill Task presents it
        /// back and is refused if a different session is active by then.
        let generation: Int
        let languageCode: String
        let prepared: PreparedSession
        let input: FastMicrophoneInput
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let resultTask: Task<FastResult, any Error>
    }

    /// Warm sessions keyed by the caller's language code. Two slots: the primary dictation
    /// language and the second-language trigger's — a second language is only worth having
    /// if it answers as fast as the first, which means keeping BOTH analyzers prepared.
    private var prepared: [String: PreparedSession] = [:]
    /// Insertion order of `prepared`, oldest first, for eviction at the cap.
    private var warmOrder: [String] = []
    private static let warmCap = 2
    /// Builds in flight, one per language. The actor is reentrant at suspension points:
    /// without this, a prewarm racing a hotkey press would start two rival model installs.
    private var buildTasks: [String: Task<PreparedSession, any Error>] = [:]
    private var active: ActiveSession?
    private var generation = 0
    /// True after `abandonAnalysis()`: the analyzer is dead but the microphone keeps
    /// capturing (the dual race's other recognizer still feeds off the raw-buffer fan-out).
    private var activeAbandoned = false
    /// AssetInventory reservations we hold, oldest first (the system caps how many).
    private var reservedLocales: [Locale] = []

    /// Language codes the new API actually supports on this machine, normalized to the app's
    /// "en-us" style. Empty when the API is unavailable.
    static func supportedLanguageCodes() async -> Set<String> {
        guard Speech.SpeechTranscriber.isAvailable else { return [] }
        let locales = await Speech.SpeechTranscriber.supportedLocales
        return Set(locales.map {
            $0.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        })
    }

    /// Build (or keep) a warm analyzer for this language so the next `start` is instant.
    func prewarm(languageCode: String) async {
        try? await ensureWarm(code: languageCode)
    }

    /// Begin a live session: microphone starts immediately, audio streams into the analyzer.
    /// `onLevel` receives a normalized 0…1 mic level per tap buffer (audio thread).
    /// `onUpdate` receives the live draft (finalized + volatile tail) as it grows.
    /// `onFailure` fires once if capture/analysis dies mid-session.
    /// `onRawBuffer` receives every UNCONVERTED microphone buffer (audio thread) — the
    /// dual-language race fans the same capture out to a second recognizer through it.
    /// Returns this session's generation token for `abandonAnalysis(generation:)`.
    @discardableResult
    func start(
        languageCode: String,
        onLevel: (@Sendable (Float) -> Void)?,
        onUpdate: (@Sendable (String) -> Void)? = nil,
        onRawBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws -> Int {
        guard active == nil else { throw FastSpeechError.sessionAlreadyActive }

        try await ensureWarm(code: languageCode)
        guard let session = prepared[languageCode] else {
            throw FastSpeechError.unavailable
        }
        prepared[languageCode] = nil
        warmOrder.removeAll { $0 == languageCode }

        let (stream, continuation) = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingNewest(64)
        )

        let transcriber = session.transcriber
        let resultTask = Task { () throws -> FastResult in
            var finalized = ""
            var volatileTail = ""
            var confidences: [Double] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finalized += text
                    volatileTail = ""
                    for run in result.text.runs {
                        if let confidence = run.transcriptionConfidence {
                            confidences.append(confidence)
                        }
                    }
                } else {
                    volatileTail = text
                }
                onUpdate?(finalized + volatileTail)
            }
            let average = confidences.isEmpty
                ? nil
                : confidences.reduce(0, +) / Double(confidences.count)
            return FastResult(text: finalized + volatileTail, confidence: average)
        }

        let input = FastMicrophoneInput(
            continuation: continuation,
            onLevel: onLevel,
            onRawBuffer: onRawBuffer,
            onFailure: onFailure
        )

        generation += 1
        active = ActiveSession(
            generation: generation,
            languageCode: languageCode,
            prepared: session,
            input: input,
            continuation: continuation,
            resultTask: resultTask
        )

        do {
            // Capture before the analyzer attaches: the stream buffers those first frames, and
            // some inputs (Bluetooth) take hundreds of ms to produce audio anyway.
            try input.start(outputFormat: session.audioFormat)
            try await session.analyzer.start(inputSequence: stream)
        } catch {
            active = nil
            continuation.finish()
            input.stop()
            await session.analyzer.cancelAndFinishNow()
            resultTask.cancel()
            reprewarm(languageCode)
            throw error
        }
        return generation
    }

    /// Dual-race early kill: this side lost — stop transcribing to save the battery, but
    /// KEEP capturing, because the raw-buffer fan-out is the other recognizer's microphone.
    /// `finish()`/`cancel()` still stop the capture and clean up.
    ///
    /// `generation` names the exact session the caller means to kill: the kill timer's
    /// detached Task can land on the actor after that session already finished and a new
    /// one (even same-language) started — the token makes killing the wrong session
    /// impossible.
    func abandonAnalysis(generation: Int) async {
        guard let session = active, session.generation == generation, !activeAbandoned else { return }
        activeAbandoned = true
        session.input.stopConverting()
        session.continuation.finish()
        await session.prepared.analyzer.cancelAndFinishNow()
        session.resultTask.cancel()
    }

    /// Stop capture, finalize whatever tail hasn't been transcribed yet, and return the text
    /// with its confidence. Near-instant: the bulk of the audio was analyzed while the user
    /// was still speaking.
    func finish() async throws -> FastResult {
        guard let session = active else { throw FastSpeechError.noActiveSession }
        active = nil

        if activeAbandoned {
            // Analysis was killed mid-race; only the microphone was still ours to stop.
            activeAbandoned = false
            session.input.stop()
            reprewarm(session.languageCode)
            return FastResult(text: "", confidence: nil)
        }

        session.input.stop()
        session.continuation.finish()

        do {
            try await session.prepared.analyzer.finalizeAndFinishThroughEndOfInput()
            let result = try await session.resultTask.value
            reprewarm(session.languageCode)
            return result
        } catch {
            session.resultTask.cancel()
            reprewarm(session.languageCode)
            throw error
        }
    }

    /// Abort the session, discarding all audio and text.
    func cancel() async {
        guard let session = active else { return }
        active = nil

        session.input.stop()
        session.continuation.finish()
        if !activeAbandoned {
            await session.prepared.analyzer.cancelAndFinishNow()
        }
        activeAbandoned = false
        session.resultTask.cancel()
        reprewarm(session.languageCode)
    }

    // MARK: - Warm session lifecycle

    private func ensureWarm(code: String) async throws {
        if prepared[code] != nil { return }

        let task: Task<PreparedSession, any Error>
        if let existing = buildTasks[code] {
            task = existing
        } else {
            let newTask = Task { try await self.makePreparedSession(code: code) }
            buildTasks[code] = newTask
            task = newTask
        }

        do {
            let session = try await task.value
            // Every awaiter caches (continuations resume in unspecified order).
            if prepared[code] == nil {
                prepared[code] = session
                warmOrder.append(code)
                // Cap the warm set: evict the oldest OTHER language.
                while warmOrder.count > Self.warmCap {
                    let evicted = warmOrder.removeFirst()
                    prepared[evicted] = nil
                }
            }
            clearBuild(task, for: code)
        } catch {
            clearBuild(task, for: code)
            throw error
        }
    }

    private func clearBuild(_ task: Task<PreparedSession, any Error>, for code: String) {
        if buildTasks[code] == task {
            buildTasks[code] = nil
        }
    }

    private func makePreparedSession(code: String) async throws -> PreparedSession {
        guard Speech.SpeechTranscriber.isAvailable else { throw FastSpeechError.unavailable }

        // `supportedLocale(equivalentTo:)` "resolves" even unsupported languages (observed on
        // macOS 26.5: it happily returns ru_RU, whose model then fails to download), so the
        // explicit supported list is the real gate.
        let supported = await Self.supportedLanguageCodes()
        guard supported.contains(code.lowercased()) else { throw FastSpeechError.unsupportedLanguage }
        guard let locale = await Speech.SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: code)
        ) else {
            throw FastSpeechError.unsupportedLanguage
        }

        await reserve(locale: locale)

        let transcriber = Speech.SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // volatile + fast: stream a live draft while the user speaks instead of waiting
            // for pauses — this is what makes finalization at stop effectively free.
            reportingOptions: [.volatileResults, .fastResults],
            // Per-word confidence feeds the dual-language race's winner pick.
            attributeOptions: [.transcriptionConfidence]
        )

        // Only a missing language model makes this slow; it downloads once per language.
        if let installationRequest = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await installationRequest.downloadAndInstall()
        }

        let modules: [any SpeechModule] = [transcriber]
        guard let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules
        ) else {
            throw FastSpeechError.missingAudioFormat
        }

        let options = SpeechAnalyzer.Options(priority: .high, modelRetention: .lingering)
        let analyzer = SpeechAnalyzer(modules: modules, options: options)
        try await analyzer.prepareToAnalyze(in: audioFormat)

        return PreparedSession(
            locale: locale,
            transcriber: transcriber,
            analyzer: analyzer,
            audioFormat: audioFormat
        )
    }

    /// Keep the warm languages reserved with AssetInventory (the reservation keeps the model
    /// installed). The system caps how many an app may hold — and it can be as low as 1 —
    /// so the oldest is released when a new one would exceed it. Failure is non-fatal: the
    /// asset may already be present system-wide.
    private func reserve(locale: Locale) async {
        if reservedLocales.contains(where: { $0.identifier == locale.identifier }) { return }
        let cap = max(1, AssetInventory.maximumReservedLocales)
        while reservedLocales.count >= cap {
            let oldest = reservedLocales.removeFirst()
            await AssetInventory.release(reservedLocale: oldest)
        }
        _ = try? await AssetInventory.reserve(locale: locale)
        reservedLocales.append(locale)
    }

    private func reprewarm(_ code: String) {
        Task { [weak self] in
            await self?.prewarm(languageCode: code)
        }
    }
}

// MARK: - Microphone input

/// Feeds live microphone audio into a SpeechAnalyzer input stream, converting from the
/// hardware format to the analyzer's preferred format. Honors the user's chosen input
/// device the same way AudioRecorder does: by temporarily switching the system default
/// input (AVAudioEngine's inputNode follows the system default), restored on stop.
@available(macOS 26.0, *)
private final class FastMicrophoneInput: @unchecked Sendable {
    /// ONE engine for the process, shared across sessions (only one fast session runs at a
    /// time). A fresh AVAudioEngine per session churns CoreAudio audio units and crashes
    /// SIGILL inside AudioConverterNew after bursts of quick dictations.
    private static let sharedEngine = AVAudioEngine()
    private var audioEngine: AVAudioEngine { Self.sharedEngine }
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let onLevel: (@Sendable (Float) -> Void)?
    private let onRawBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private let onFailure: @Sendable (String) -> Void
    private let stateLock = NSLock()
    private var running = false
    private var reportedFailure = false
    /// False after the dual race kills this side: capture continues (levels + raw fan-out)
    /// but the format conversion and analyzer feed stop burning CPU.
    private var converting = true
    private var previousDefaultInputDeviceID: AudioDeviceID?

    /// Stop feeding the analyzer while keeping the microphone hot for the raw-buffer fan-out.
    func stopConverting() {
        stateLock.lock()
        converting = false
        stateLock.unlock()
    }

    /// One-shot input provider for AVAudioConverter: hands the buffer once, then reports
    /// `.noDataNow` so each tap buffer maps to exactly one convert call.
    private final class InputProvider: @unchecked Sendable {
        private let buffer: AVAudioPCMBuffer
        private let lock = NSLock()
        private var supplied = false

        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            lock.lock()
            defer { lock.unlock() }
            guard !supplied else {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }

    init(
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        onLevel: (@Sendable (Float) -> Void)?,
        onRawBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.continuation = continuation
        self.onLevel = onLevel
        self.onRawBuffer = onRawBuffer
        self.onFailure = onFailure
    }

    func start(outputFormat: AVAudioFormat) throws {
        applySelectedInputDevice()

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            restoreDefaultInputDevice()
            throw FastSpeechService.FastSpeechError.microphoneUnavailable
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            restoreDefaultInputDevice()
            throw FastSpeechService.FastSpeechError.microphoneUnavailable
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.receive(buffer, converter: converter, outputFormat: outputFormat)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            stateLock.lock()
            running = true
            stateLock.unlock()
        } catch {
            inputNode.removeTap(onBus: 0)
            restoreDefaultInputDevice()
            throw error
        }
    }

    func stop() {
        stateLock.lock()
        let shouldStop = running
        running = false
        stateLock.unlock()

        guard shouldStop else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        restoreDefaultInputDevice()
    }

    // MARK: Input device (mirrors AudioRecorder)

    private func applySelectedInputDevice() {
        previousDefaultInputDeviceID = nil
        let savedID = SettingsManager.shared.selectedInputDeviceID
        guard !savedID.isEmpty else { return }
        guard let target = AudioInputDevices.available().first(where: { $0.uniqueID == savedID }) else {
            return
        }
        if let current = AudioInputDevices.currentDefaultInputDeviceID(), current != target.coreAudioID {
            previousDefaultInputDeviceID = current
            AudioInputDevices.setDefaultInputDevice(target.coreAudioID)
        }
    }

    private func restoreDefaultInputDevice() {
        if let previous = previousDefaultInputDeviceID {
            AudioInputDevices.setDefaultInputDevice(previous)
            previousDefaultInputDeviceID = nil
        }
    }

    // MARK: Audio path (audio thread)

    private func receive(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        publishLevel(of: buffer)
        onRawBuffer?(buffer)

        stateLock.lock()
        let stillConverting = converting
        stateLock.unlock()
        guard stillConverting else { return }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            reportFailure("Unable to allocate an audio buffer.")
            return
        }

        let provider = InputProvider(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            provider.next(status: inputStatus)
        }

        if let conversionError {
            reportFailure("Microphone conversion failed: \(conversionError.localizedDescription)")
            return
        }
        guard status == .haveData || status == .inputRanDry else {
            reportFailure("Microphone conversion failed (status \(status.rawValue)).")
            return
        }

        if case .dropped = continuation.yield(AnalyzerInput(buffer: outputBuffer)) {
            reportFailure("Speech analysis could not keep up with microphone input.")
        }
    }

    /// RMS of the first channel mapped to 0…1 over a 50 dB window — the same scale
    /// AudioRecorder feeds the overlay and the silent-mic guard.
    private func publishLevel(of buffer: AVAudioPCMBuffer) {
        guard let onLevel,
              let samples = buffer.floatChannelData?[0],
              buffer.frameLength > 0
        else { return }

        let rms = vDSP.rootMeanSquare(
            UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))
        )
        let db = 20 * log10(max(rms, .leastNormalMagnitude))
        onLevel(min(1, max(0, (db + 50) / 50)))
    }

    private func reportFailure(_ message: String) {
        stateLock.lock()
        let shouldReport = !reportedFailure
        reportedFailure = true
        stateLock.unlock()

        guard shouldReport else { return }
        continuation.finish()
        onFailure(message)
    }
}

//
//  SpeechTranscriber.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import Foundation
import Speech
import AVFoundation
import Accelerate
import CoreAudio

class SpeechTranscriber {
    private var recognizer: SFSpeechRecognizer?
    private var selectedLanguage: String = "en-US"
    var onProgress: ((Double) -> Void)?

    /// The in-flight recognition task and its delegate are retained here for the lifetime of a
    /// transcription. SFSpeechRecognitionTaskDelegate is held weakly by the task, so without our
    /// own strong reference the delegate would deallocate mid-recognition and we'd get no result.
    private var activeTask: SFSpeechRecognitionTask?
    private var activeDelegate: SegmentAccumulatingDelegate?

    // MARK: Live (streaming) session state
    // Used by the Apple Live engine's fallback for languages the new SpeechAnalyzer doesn't
    // cover (Russian!): audio streams into SFSpeechRecognizer WHILE the user speaks, so the
    // result at stop is near-instant, versus the classic record-file-then-transcribe path.
    private var liveEngine: AVAudioEngine?
    private var liveRequest: SFSpeechAudioBufferRecognitionRequest?
    private var liveTask: SFSpeechRecognitionTask?
    private var liveDelegate: SegmentAccumulatingDelegate?
    private var liveFinishCompletion: ((Result<String, Error>) -> Void)?
    private var liveOnFailure: ((String) -> Void)?
    /// Previous system default input, stashed while we honor the user's chosen microphone
    /// (AVAudioEngine's inputNode follows the system default) — restored on stop.
    private var livePreviousDefaultInputID: AudioDeviceID?

    var isReady: Bool {
        recognizer?.isAvailable ?? false
    }

    func configure(language: String) {
        self.selectedLanguage = language

        // Apple's SFSpeechRecognizer has no true "auto" mode, so for "auto" we fall back to the
        // user's current locale. If the requested locale has no recognizer (or it's unavailable),
        // gracefully fall back to the current locale and then to en-US.
        let requested: Locale = (language == DictationLanguage.autoCode)
            ? Locale.current
            : Locale(identifier: language)

        var chosen = SFSpeechRecognizer(locale: requested)
        if chosen == nil || chosen?.isAvailable == false {
            chosen = SFSpeechRecognizer(locale: Locale.current)
        }
        if chosen == nil || chosen?.isAvailable == false {
            chosen = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        }
        recognizer = chosen
        recognizer?.supportsOnDeviceRecognition = true

        // Request authorization
        SFSpeechRecognizer.requestAuthorization { status in
            switch status {
            case .denied:
                print("mywisper: Speech recognition denied")
            case .restricted:
                print("mywisper: Speech recognition restricted")
            default:
                break
            }
        }

    }

    func setLanguage(_ language: String) {
        configure(language: language)
    }

    func transcribe(audioFileURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            completion(.failure(TranscriberError.recognizerUnavailable))
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: audioFileURL)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = false

        // For audio longer than a single utterance, SFSpeechRecognizer divides the file into
        // pause-separated segments and reports a *separate* final result for each one. The old
        // implementation called the completion handler on every final result, so downstream each
        // segment overwrote the previous — only the last segment survived and the beginning was
        // lost (the "loses the start of recordings over a couple of minutes" report).
        //
        // We instead accumulate every finalized segment in order and deliver the concatenation
        // exactly once, when the recognizer signals it has finished the whole file. A delegate is
        // used because only the delegate exposes that terminal "finished successfully" callback;
        // the resultHandler API gives no clean end-of-file signal.
        let delegate = SegmentAccumulatingDelegate { [weak self] result, _ in
            // Recognition is over (success or failure) — drop our strong references so the task
            // and delegate can deallocate.
            self?.activeTask = nil
            self?.activeDelegate = nil
            completion(result)
        }
        activeDelegate = delegate
        activeTask = recognizer.recognitionTask(with: request, delegate: delegate)
    }

    // MARK: - Live (streaming) session

    private var liveActive = false
    var liveSessionActive: Bool { liveActive }

    /// Average segment confidence (0…1) of the last finished live session — the dual
    /// language race's main signal: the recognizer fed the wrong language scores low.
    private(set) var lastLiveAverageConfidence: Double = 0

    /// Start live recognition WITHOUT owning the microphone: buffers arrive from outside
    /// via `appendLiveBuffer` (the dual-language race taps the mic once and fans out).
    func startLiveSessionFeed(
        onPartial: ((String) -> Void)? = nil,
        onFailure: @escaping (String) -> Void
    ) throws {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw TranscriberError.recognizerUnavailable
        }
        guard !liveActive else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        let delegate = SegmentAccumulatingDelegate(onPartial: onPartial) { [weak self] result, confidence in
            self?.lastLiveAverageConfidence = confidence
            self?.liveRecognitionCompleted(with: result)
        }

        liveRequest = request
        liveDelegate = delegate
        liveOnFailure = onFailure
        liveFinishCompletion = nil
        liveActive = true
        liveTask = recognizer.recognitionTask(with: request, delegate: delegate)
    }

    /// Feed one microphone buffer into a feed-mode live session (audio thread).
    func appendLiveBuffer(_ buffer: AVAudioPCMBuffer) {
        liveRequest?.append(buffer)
    }

    /// Start streaming microphone audio into the recognizer. Partial recognition runs while the
    /// user speaks; `finishLiveSession` then only finalizes the tail, so the result is
    /// near-instant. `onLevel` gets a normalized 0…1 mic level per buffer (audio thread);
    /// `onFailure` fires once if recognition dies mid-session (before finish is called).
    func startLiveSession(
        onLevel: ((Float) -> Void)?,
        onPartial: ((String) -> Void)? = nil,
        onFailure: @escaping (String) -> Void
    ) throws {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw TranscriberError.recognizerUnavailable
        }
        guard liveEngine == nil else { return }

        applyLiveSelectedInputDevice()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            restoreLiveDefaultInputDevice()
            throw TranscriberError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        let delegate = SegmentAccumulatingDelegate(onPartial: onPartial) { [weak self] result, confidence in
            self?.lastLiveAverageConfidence = confidence
            self?.liveRecognitionCompleted(with: result)
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            self?.liveRequest?.append(buffer)
            guard let onLevel,
                  let samples = buffer.floatChannelData?[0],
                  buffer.frameLength > 0 else { return }
            let rms = vDSP.rootMeanSquare(
                UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))
            )
            let db = 20 * log10(max(rms, .leastNormalMagnitude))
            onLevel(min(1, max(0, (db + 50) / 50)))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            restoreLiveDefaultInputDevice()
            throw error
        }

        liveEngine = engine
        liveRequest = request
        liveDelegate = delegate
        liveOnFailure = onFailure
        liveFinishCompletion = nil
        liveActive = true
        liveTask = recognizer.recognitionTask(with: request, delegate: delegate)
    }

    /// Stop capturing and finalize. The recognizer already processed the audio while the user
    /// spoke, so the delegate's terminal callback lands within a fraction of a second.
    func finishLiveSession(completion: @escaping (Result<String, Error>) -> Void) {
        guard liveActive else {
            completion(.failure(TranscriberError.recognizerUnavailable))
            return
        }
        liveFinishCompletion = completion
        stopLiveAudio()
        liveRequest?.endAudio()
    }

    /// Abort the live session, discarding all audio and text.
    func cancelLiveSession() {
        guard liveActive else { return }
        liveActive = false
        liveFinishCompletion = nil
        liveOnFailure = nil
        stopLiveAudio()
        liveTask?.cancel()
        liveTask = nil
        liveRequest = nil
        liveDelegate = nil
    }

    /// Terminal delegate callback for the live session (may arrive on any queue).
    private func liveRecognitionCompleted(with result: Result<String, Error>) {
        liveActive = false
        let completion = liveFinishCompletion
        let failure = liveOnFailure
        liveFinishCompletion = nil
        liveOnFailure = nil
        liveTask = nil
        liveRequest = nil
        liveDelegate = nil
        stopLiveAudio()

        if let completion {
            completion(result)
        } else if case .failure(let error) = result, let failure {
            // Died mid-recording, before finish was requested.
            failure(error.localizedDescription)
        }
    }

    private func stopLiveAudio() {
        guard let engine = liveEngine else { return }
        liveEngine = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        restoreLiveDefaultInputDevice()
    }

    // Honor the user's chosen input device (mirrors AudioRecorder).
    private func applyLiveSelectedInputDevice() {
        livePreviousDefaultInputID = nil
        let savedID = SettingsManager.shared.selectedInputDeviceID
        guard !savedID.isEmpty else { return }
        guard let target = AudioInputDevices.available().first(where: { $0.uniqueID == savedID }) else {
            return
        }
        if let current = AudioInputDevices.currentDefaultInputDeviceID(), current != target.coreAudioID {
            livePreviousDefaultInputID = current
            AudioInputDevices.setDefaultInputDevice(target.coreAudioID)
        }
    }

    private func restoreLiveDefaultInputDevice() {
        if let previous = livePreviousDefaultInputID {
            AudioInputDevices.setDefaultInputDevice(previous)
            livePreviousDefaultInputID = nil
        }
    }
}

/// Collects every finalized speech segment for one recognition request and joins them in order,
/// delivering the combined transcript once the recognizer finishes reading the whole file.
private final class SegmentAccumulatingDelegate: NSObject, SFSpeechRecognitionTaskDelegate {
    private var segments: [String] = []
    private var didComplete = false
    /// Per-word confidences across every finalized segment; their average is the
    /// dual-language race's score for this recognizer.
    private var confidences: [Double] = []
    private let completion: (Result<String, Error>, Double) -> Void
    /// Live-draft feed: finalized segments plus the current in-progress hypothesis.
    /// nil for file-based transcription, where nobody watches partials.
    private let onPartial: ((String) -> Void)?

    init(onPartial: ((String) -> Void)? = nil, completion: @escaping (Result<String, Error>, Double) -> Void) {
        self.onPartial = onPartial
        self.completion = completion
    }

    private var averageConfidence: Double {
        confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
    }

    /// Streaming hypothesis for the CURRENT segment (cumulative within it, replaced on the
    /// next). Joined after the finalized segments it extends.
    func speechRecognitionTask(
        _ task: SFSpeechRecognitionTask,
        didHypothesizeTranscription transcription: SFTranscription
    ) {
        guard let onPartial else { return }
        let partial = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = (segments + (partial.isEmpty ? [] : [partial])).joined(separator: " ")
        onPartial(combined)
    }

    /// Called once for each finalized segment of the audio. These results are per-segment (not
    /// cumulative), so we append. We guard against an exact immediate repeat of the previous
    /// segment in case the recognizer emits a duplicate final callback.
    func speechRecognitionTask(
        _ task: SFSpeechRecognitionTask,
        didFinishRecognition recognitionResult: SFSpeechRecognitionResult
    ) {
        let transcription = recognitionResult.bestTranscription
        let text = transcription.formattedString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if text == segments.last { return }
        segments.append(text)
        confidences.append(contentsOf: transcription.segments.map { Double($0.confidence) })
    }

    /// Terminal callback: the recognizer has finished the entire file (or failed/cancelled).
    /// Deliver the accumulated transcript exactly once.
    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
        guard !didComplete else { return }
        didComplete = true

        let combined = segments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        if successfully || !combined.isEmpty {
            // Succeeded — or it ended with an error but we still captured usable text; return what
            // we have rather than discarding the user's words.
            completion(.success(combined), averageConfidence)
        } else if let error = task.error {
            completion(.failure(error), 0)
        } else {
            completion(.failure(TranscriberError.recognizerUnavailable), 0)
        }
    }
}

enum TranscriberError: Error, LocalizedError {
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognizer is not available. Check language settings."
        }
    }
}

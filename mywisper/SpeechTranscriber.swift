//
//  SpeechTranscriber.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import Foundation
import Speech

class SpeechTranscriber {
    private var recognizer: SFSpeechRecognizer?
    private var selectedLanguage: String = "en-US"
    var onProgress: ((Double) -> Void)?

    /// The in-flight recognition task and its delegate are retained here for the lifetime of a
    /// transcription. SFSpeechRecognitionTaskDelegate is held weakly by the task, so without our
    /// own strong reference the delegate would deallocate mid-recognition and we'd get no result.
    private var activeTask: SFSpeechRecognitionTask?
    private var activeDelegate: SegmentAccumulatingDelegate?

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
        let delegate = SegmentAccumulatingDelegate { [weak self] result in
            // Recognition is over (success or failure) — drop our strong references so the task
            // and delegate can deallocate.
            self?.activeTask = nil
            self?.activeDelegate = nil
            completion(result)
        }
        activeDelegate = delegate
        activeTask = recognizer.recognitionTask(with: request, delegate: delegate)
    }
}

/// Collects every finalized speech segment for one recognition request and joins them in order,
/// delivering the combined transcript once the recognizer finishes reading the whole file.
private final class SegmentAccumulatingDelegate: NSObject, SFSpeechRecognitionTaskDelegate {
    private var segments: [String] = []
    private var didComplete = false
    private let completion: (Result<String, Error>) -> Void

    init(completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion
    }

    /// Called once for each finalized segment of the audio. These results are per-segment (not
    /// cumulative), so we append. We guard against an exact immediate repeat of the previous
    /// segment in case the recognizer emits a duplicate final callback.
    func speechRecognitionTask(
        _ task: SFSpeechRecognitionTask,
        didFinishRecognition recognitionResult: SFSpeechRecognitionResult
    ) {
        let text = recognitionResult.bestTranscription.formattedString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if text == segments.last { return }
        segments.append(text)
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
            completion(.success(combined))
        } else if let error = task.error {
            completion(.failure(error))
        } else {
            completion(.failure(TranscriberError.recognizerUnavailable))
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

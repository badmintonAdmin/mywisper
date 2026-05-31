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

        recognizer.recognitionTask(with: request) { result, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let result = result else { return }

            if result.isFinal {
                let text = result.bestTranscription.formattedString
                completion(.success(text))
            }
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

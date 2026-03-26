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
        let locale = Locale(identifier: language)
        recognizer = SFSpeechRecognizer(locale: locale)
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

//
//  CloudWhisperService.swift
//  mywisper
//
//  Created by Сергей Борисов on 23.03.2026.
//

import Foundation

class CloudWhisperService {
    static let shared = CloudWhisperService()

    func transcribe(
        audioFileURL: URL,
        apiKey: String,
        language: String,
        prompt: String?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard !apiKey.isEmpty else {
            completion(.failure(OpenAIError.noAPIKey))
            return
        }

        guard let audioData = try? Data(contentsOf: audioFileURL) else {
            completion(.failure(CloudWhisperError.cannotReadAudioFile))
            return
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var body = Data()

        // model field
        body.appendMultipartField(boundary: boundary, name: "model", value: "whisper-1")

        // language field (convert "en-US" → "en", "ru-RU" → "ru")
        let langCode = String(language.prefix(2)).lowercased()
        body.appendMultipartField(boundary: boundary, name: "language", value: langCode)

        // response_format field
        body.appendMultipartField(boundary: boundary, name: "response_format", value: "text")

        // prompt field (vocabulary hints)
        if let prompt = prompt, !prompt.isEmpty {
            body.appendMultipartField(boundary: boundary, name: "prompt", value: prompt)
        }

        // file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // closing boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1

            guard let data = data else {
                completion(.failure(OpenAIError.noResponse))
                return
            }

            // Check HTTP status
            if httpStatus != 200 {
                let body = String(data: data, encoding: .utf8) ?? "unknown"
                if let errorResponse = try? JSONDecoder().decode(OpenAIService.ErrorResponse.self, from: data) {
                    completion(.failure(OpenAIError.apiError(errorResponse.error.message)))
                } else {
                    completion(.failure(OpenAIError.apiError("HTTP \(httpStatus): \(body)")))
                }
                return
            }

            // response_format=text returns plain text
            if let text = String(data: data, encoding: .utf8) {
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(.success(cleaned))
            } else {
                completion(.failure(OpenAIError.emptyResponse))
            }
        }.resume()
    }
}

enum CloudWhisperError: Error, LocalizedError {
    case cannotReadAudioFile

    var errorDescription: String? {
        switch self {
        case .cannotReadAudioFile:
            return "Cannot read audio file for cloud transcription."
        }
    }
}

// MARK: - Multipart helpers

private extension Data {
    mutating func appendMultipartField(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}

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
            completion(.failure(CloudWhisperError.noAPIKey))
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
            if let urlError = error as? URLError {
                completion(.failure(CloudWhisperError.network(urlError)))
                return
            }
            if let error = error {
                completion(.failure(error))
                return
            }

            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1

            guard let data = data else {
                completion(.failure(CloudWhisperError.noResponse))
                return
            }

            // Check HTTP status
            if httpStatus != 200 {
                let body: String
                if let errorResponse = try? JSONDecoder().decode(OpenAIService.ErrorResponse.self, from: data) {
                    body = errorResponse.error.message
                } else {
                    body = String(data: data, encoding: .utf8) ?? "unknown"
                }
                completion(.failure(CloudWhisperError.httpStatus(code: httpStatus, body: body)))
                return
            }

            // response_format=text returns plain text
            if let text = String(data: data, encoding: .utf8) {
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(.success(cleaned))
            } else {
                completion(.failure(CloudWhisperError.emptyResponse))
            }
        }.resume()
    }

    /// Classifies whether an error is worth retrying. Network glitches, request timeouts,
    /// rate limits and 5xx are transient; auth and client errors are not.
    static func isTransient(_ error: Error) -> Bool {
        if case CloudWhisperError.network(let urlErr) = error {
            return [
                .timedOut,
                .notConnectedToInternet,
                .networkConnectionLost,
                .cannotConnectToHost,
                .dnsLookupFailed,
                .cannotFindHost,
                .resourceUnavailable
            ].contains(urlErr.code)
        }
        if let urlErr = error as? URLError {
            return [
                .timedOut,
                .notConnectedToInternet,
                .networkConnectionLost,
                .cannotConnectToHost,
                .dnsLookupFailed,
                .cannotFindHost,
                .resourceUnavailable
            ].contains(urlErr.code)
        }
        if case CloudWhisperError.httpStatus(let code, _) = error {
            return code == 429 || (500...599).contains(code)
        }
        return false
    }
}

enum CloudWhisperError: Error, LocalizedError {
    case noAPIKey
    case cannotReadAudioFile
    case network(URLError)
    case httpStatus(code: Int, body: String)
    case noResponse
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "OpenAI API key not set. Add it in Settings → AI Processing."
        case .cannotReadAudioFile:
            return "Cannot read audio file for cloud transcription."
        case .network(let urlErr):
            return "Network error: \(urlErr.localizedDescription)"
        case .httpStatus(let code, let body):
            return "OpenAI HTTP \(code): \(body)"
        case .noResponse:
            return "No response from OpenAI."
        case .emptyResponse:
            return "Empty response from OpenAI."
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

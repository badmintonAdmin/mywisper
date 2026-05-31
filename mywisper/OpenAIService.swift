//
//  OpenAIService.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import Foundation

class OpenAIService {
    static let shared = OpenAIService()

    struct ChatMessage: Codable {
        let role: String
        let content: String
    }

    struct ChatRequest: Codable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
        let max_tokens: Int
    }

    struct ChatResponse: Codable {
        struct Choice: Codable {
            struct Message: Codable {
                let content: String
            }
            let message: Message
        }
        let choices: [Choice]
    }

    struct ErrorResponse: Codable {
        struct ErrorDetail: Codable {
            let message: String
        }
        let error: ErrorDetail
    }

    /// Lightweight key validation: hits the `/v1/models` endpoint with the given key.
    /// Succeeds on HTTP 200, fails with a friendly message otherwise. Used by the
    /// "Test key" button in Settings so an invalid key surfaces before the first dictation.
    func validateKey(_ apiKey: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(OpenAIError.noAPIKey))
            return
        }

        let url = URL(string: "https://api.openai.com/v1/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(OpenAIError.noResponse))
                return
            }
            if http.statusCode == 200 {
                completion(.success(()))
                return
            }
            // Surface the API's own message when present (e.g. "Incorrect API key provided").
            if let data = data,
               let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                completion(.failure(OpenAIError.apiError(errorResponse.error.message)))
            } else {
                completion(.failure(OpenAIError.apiError("HTTP \(http.statusCode)")))
            }
        }.resume()
    }

    func process(
        text: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard !apiKey.isEmpty else {
            completion(.failure(OpenAIError.noAPIKey))
            return
        }

        guard !text.isEmpty else {
            completion(.success(text))
            return
        }

        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: text)
        ]

        let chatRequest = ChatRequest(
            model: model,
            messages: messages,
            temperature: 0.3,
            max_tokens: 4096
        )

        do {
            request.httpBody = try JSONEncoder().encode(chatRequest)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(OpenAIError.noResponse))
                return
            }

            // Check for API error
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                completion(.failure(OpenAIError.apiError(errorResponse.error.message)))
                return
            }

            do {
                let response = try JSONDecoder().decode(ChatResponse.self, from: data)
                if let result = response.choices.first?.message.content {
                    let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    completion(.success(cleaned))
                } else {
                    completion(.failure(OpenAIError.emptyResponse))
                }
            } catch {
                completion(.failure(OpenAIError.parseError))
            }
        }.resume()
    }
}

enum OpenAIError: Error, LocalizedError {
    case noAPIKey
    case noResponse
    case emptyResponse
    case parseError
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "OpenAI API key not set. Add it in Settings → AI Processing."
        case .noResponse:
            return "No response from OpenAI."
        case .emptyResponse:
            return "Empty response from OpenAI."
        case .parseError:
            return "Failed to parse OpenAI response."
        case .apiError(let msg):
            return "OpenAI: \(msg)"
        }
    }
}

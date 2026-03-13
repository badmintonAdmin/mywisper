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

        print("mywisper: Sending to OpenAI (\(model))...")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("mywisper: OpenAI network error: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(OpenAIError.noResponse))
                return
            }

            // Check for API error
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                print("mywisper: OpenAI API error: \(errorResponse.error.message)")
                completion(.failure(OpenAIError.apiError(errorResponse.error.message)))
                return
            }

            do {
                let response = try JSONDecoder().decode(ChatResponse.self, from: data)
                if let result = response.choices.first?.message.content {
                    let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    print("mywisper: OpenAI result: '\(cleaned.prefix(80))'")
                    completion(.success(cleaned))
                } else {
                    completion(.failure(OpenAIError.emptyResponse))
                }
            } catch {
                print("mywisper: OpenAI parse error: \(error)")
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

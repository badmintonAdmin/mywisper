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

    // MARK: - Chunking configuration

    /// Per-request output ceiling we send to the API. Long transcripts are split so each
    /// chunk's cleaned output stays comfortably under this.
    private static let maxTokensPerRequest = 4096

    /// Conservative tokens-per-character ratio. Cyrillic tokenizes far denser than English
    /// (~1 token per 2 chars), so we assume the dense case to decide when to split — over-
    /// estimating only makes us chunk a bit earlier, which is safe.
    private static let tokensPerChar = 0.4

    /// If the estimated cleaned output would exceed this many tokens, we split the input into
    /// chunks rather than risk the API truncating the tail at `maxTokensPerRequest`. Sits below
    /// the request ceiling to leave headroom for the model lightly expanding the text.
    private static let chunkOutputTokenThreshold = 3200

    /// Target output tokens per chunk when splitting. Translated to a character budget via
    /// `tokensPerChar`. Kept well under the threshold so each chunk has slack.
    private static let chunkTargetOutputTokens = 2400

    private func estimatedOutputTokens(_ text: String) -> Int {
        Int(Double(text.count) * Self.tokensPerChar)
    }

    /// Entry point for AI post-processing. Short/medium transcripts go straight to a single
    /// request (unchanged fast path). Long transcripts are split on sentence boundaries and the
    /// chunks are processed *in parallel*, then re-joined in order — so a 15-minute dictation no
    /// longer loses its tail to the `max_tokens` ceiling, without a meaningful latency hit.
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

        // Fast path: the cleaned output comfortably fits one request.
        guard estimatedOutputTokens(text) > Self.chunkOutputTokenThreshold else {
            processChunk(text: text, apiKey: apiKey, model: model, systemPrompt: systemPrompt, completion: completion)
            return
        }

        // Long transcript: split on sentence boundaries and process chunks concurrently.
        let maxChars = Int(Double(Self.chunkTargetOutputTokens) / Self.tokensPerChar)
        let chunks = Self.splitIntoChunks(text, maxChars: maxChars)

        // Defensive: if splitting somehow produced a single chunk, just process it directly.
        guard chunks.count > 1 else {
            processChunk(text: text, apiKey: apiKey, model: model, systemPrompt: systemPrompt, completion: completion)
            return
        }

        var results = [String?](repeating: nil, count: chunks.count)
        var firstError: Error?
        let lock = NSLock()
        let group = DispatchGroup()

        for (index, chunk) in chunks.enumerated() {
            group.enter()
            processChunk(text: chunk, apiKey: apiKey, model: model, systemPrompt: systemPrompt) { result in
                lock.lock()
                switch result {
                case .success(let cleaned):
                    results[index] = cleaned
                case .failure(let error):
                    if firstError == nil { firstError = error }
                }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            // Any chunk failing fails the whole step; the caller falls back to the raw
            // (unprocessed) transcript, so the user never loses words to an AI error.
            if let error = firstError {
                completion(.failure(error))
                return
            }
            let joined = results.compactMap { $0 }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            completion(.success(joined))
        }
    }

    /// Split `text` into chunks no larger than `maxChars`, breaking only at sentence boundaries
    /// so the AI never sees a sentence cut in half. A lone sentence longer than `maxChars`
    /// (rare run-on / no punctuation) is hard-split on whitespace as a last resort.
    static func splitIntoChunks(_ text: String, maxChars: Int) -> [String] {
        guard maxChars > 0 else { return [text] }

        // Break into sentences, keeping the terminator and any trailing whitespace attached.
        let terminators: Set<Character> = [".", "!", "?", "…", "\n"]
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if terminators.contains(ch) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty { sentences.append(current) }

        var chunks: [String] = []
        var buffer = ""
        for sentence in sentences {
            // A single oversized sentence: flush the buffer, then hard-split the sentence.
            if sentence.count > maxChars {
                if !buffer.isEmpty { chunks.append(buffer); buffer = "" }
                chunks.append(contentsOf: hardSplit(sentence, maxChars: maxChars))
                continue
            }
            if buffer.count + sentence.count > maxChars && !buffer.isEmpty {
                chunks.append(buffer)
                buffer = ""
            }
            buffer += sentence
        }
        if !buffer.isEmpty { chunks.append(buffer) }
        return chunks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Last-resort splitter for a single sentence longer than `maxChars`: packs whole words up
    /// to the limit (falling back to a raw character cut for a single word over the limit).
    private static func hardSplit(_ text: String, maxChars: Int) -> [String] {
        var pieces: [String] = []
        var buffer = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let candidate = buffer.isEmpty ? String(word) : buffer + " " + word
            if candidate.count > maxChars && !buffer.isEmpty {
                pieces.append(buffer)
                buffer = String(word)
            } else if candidate.count > maxChars {
                // Single word longer than the limit — chop it into fixed-size slices.
                var w = String(word)
                while w.count > maxChars {
                    pieces.append(String(w.prefix(maxChars)))
                    w = String(w.dropFirst(maxChars))
                }
                buffer = w
            } else {
                buffer = candidate
            }
        }
        if !buffer.isEmpty { pieces.append(buffer) }
        return pieces
    }

    /// Perform a single chat-completion request for one chunk of text.
    private func processChunk(
        text: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
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
            max_tokens: Self.maxTokensPerRequest
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

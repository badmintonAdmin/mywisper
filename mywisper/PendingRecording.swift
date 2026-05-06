//
//  PendingRecording.swift
//  mywisper
//
//  Created by Сергей Борисов on 06.05.2026.
//

import Foundation

/// Audio that has been recorded but not yet successfully transcribed via the cloud engine.
/// Stored on disk so it survives app crashes and can be retried after network failures.
struct PendingRecording: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let durationSeconds: TimeInterval
    let language: String
    let prompt: String?
    var lastError: String?
    var retryCount: Int

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        durationSeconds: TimeInterval,
        language: String,
        prompt: String?,
        lastError: String? = nil,
        retryCount: Int = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.language = language
        self.prompt = prompt
        self.lastError = lastError
        self.retryCount = retryCount
    }
}

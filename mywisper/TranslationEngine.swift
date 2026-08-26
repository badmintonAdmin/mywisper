//
//  TranslationEngine.swift
//  mywisper
//
//  On-device dictation translation via Apple's Translation framework (macOS 15+),
//  after Talkify's Translation module. Key facts their code documents:
//  - `TranslationSession(installedSource:target:)` is the ONLY direct initializer
//    and it throws at once for a pair this Mac doesn't already have — it never
//    downloads. The only API that installs a model is the `.translationTask` View
//    modifier, so downloads happen from the Settings window
//    (TranslationDownloadTaskView below); the menu-bar session just uses what's
//    installed.
//  - Sessions are prewarmed and cached per pair; a cancelled session throws
//    `alreadyCancelled` forever after, so it must be discarded, not reused.
//  - Translation is raced against a timeout: warm ≈ 250–410 ms, cold ≈ 0.6–1 s
//    per sentence (Talkify's measurements), so 6 s means "wedged", not "slow".
//

import Foundation
import SwiftUI
import Translation

@available(macOS 26.0, *)
actor TranslationEngine {
    static let shared = TranslationEngine()

    struct Pair: Hashable, Sendable {
        let source: String  // ISO language code, e.g. "en"
        let target: String

        var sourceLanguage: Locale.Language { Locale.Language(identifier: source) }
        var targetLanguage: Locale.Language { Locale.Language(identifier: target) }
    }

    enum Availability: Sendable {
        case installed
        case downloadable
        case unsupported
    }

    enum TranslationError: LocalizedError {
        case notInstalled
        case unsupported
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "The translation model isn't downloaded — get it in Settings → Language."
            case .unsupported:
                return "This language pair isn't supported by Apple Translation."
            case .timedOut:
                return "Translation timed out."
            }
        }
    }

    /// Task requires a Sendable success value; the session never actually
    /// leaves this actor's isolation.
    private struct Held: @unchecked Sendable {
        let session: TranslationSession
    }

    private var sessions: [Pair: Held] = [:]
    /// In-flight builds, so a translate keypress during a prepare joins it
    /// instead of starting a rival one (the actor is reentrant at suspensions).
    private var buildTasks: [Pair: Task<Held, any Error>] = [:]

    /// Long enough for a long draft, short enough that a wedged translator
    /// can't hold the user's words hostage.
    static let timeout: Duration = .seconds(6)

    func availability(of pair: Pair) async -> Availability {
        switch await LanguageAvailability().status(from: pair.sourceLanguage, to: pair.targetLanguage) {
        case .installed: return .installed
        case .supported: return .downloadable
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Loads an installed pair so the first translate keypress is warm.
    /// Never throws and never downloads — a missing model must not break the
    /// dictation this runs alongside.
    func prewarm(_ pair: Pair) async {
        guard await availability(of: pair) == .installed else { return }
        _ = try? await held(for: pair)
    }

    /// Drops every held session except this pair's (Settings changed the target).
    func retainOnly(_ pair: Pair?) {
        sessions = sessions.filter { $0.key == pair }
        for (key, task) in buildTasks where key != pair {
            task.cancel()
            buildTasks[key] = nil
        }
    }

    func translate(_ text: String, pair: Pair) async throws -> String {
        // Silence is not a failure, but Apple's translator reports it as one.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        switch await availability(of: pair) {
        case .unsupported: throw TranslationError.unsupported
        case .downloadable: throw TranslationError.notInstalled
        case .installed: break
        }

        // Race the translation against the budget; the loser is cancelled.
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await self.performTranslate(trimmed, pair: pair)
            }
            group.addTask {
                try await Task.sleep(for: Self.timeout)
                throw TranslationError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TranslationError.timedOut }
            return first
        }
    }

    private func performTranslate(_ text: String, pair: Pair) async throws -> String {
        let held = try await held(for: pair)
        return try await withTaskCancellationHandler {
            try await held.session.translate(text).targetText
        } onCancel: {
            // A cancelled session is dead from then on — throw it away so the
            // next translate builds a fresh one.
            Task { await self.discard(held.session, for: pair) }
            held.session.cancel()
        }
    }

    private func discard(_ session: TranslationSession, for pair: Pair) {
        guard sessions[pair]?.session === session else { return }
        sessions[pair] = nil
    }

    private func held(for pair: Pair) async throws -> Held {
        if let existing = sessions[pair] { return existing }
        if let building = buildTasks[pair] {
            return try await awaitCancellable(building)
        }

        let task = Task<Held, any Error> {
            let session = TranslationSession(
                installedSource: pair.sourceLanguage,
                target: pair.targetLanguage
            )
            try await session.prepareTranslation()
            return Held(session: session)
        }
        buildTasks[pair] = task

        do {
            let built = try await awaitCancellable(task)
            if buildTasks[pair] == task {
                buildTasks[pair] = nil
                sessions[pair] = built
            }
            return built
        } catch {
            if buildTasks[pair] == task { buildTasks[pair] = nil }
            throw error
        }
    }

    /// `await task.value` ignores the awaiting task's cancellation; this keeps
    /// the timeout race able to actually cancel a stuck prepare.
    private func awaitCancellable(_ task: Task<Held, any Error>) async throws -> Held {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

// MARK: - Model download host (Settings only)

/// Presents Apple's translation download sheet. A zero-size view, because of
/// where Apple put the download: `.translationTask` is the only API that
/// installs a model, and it needs a window — Settings has one, the menu-bar
/// session does not. Going from nil to a pair presents the sheet; the call
/// does not return when the download finishes, so callers watch availability.
@available(macOS 26.0, *)
struct TranslationDownloadTaskView: View {
    let pair: TranslationEngine.Pair?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(configuration) { @Sendable session in
                try? await session.prepareTranslation()
            }
    }

    private var configuration: TranslationSession.Configuration? {
        guard let pair else { return nil }
        return TranslationSession.Configuration(
            source: pair.sourceLanguage,
            target: pair.targetLanguage
        )
    }
}

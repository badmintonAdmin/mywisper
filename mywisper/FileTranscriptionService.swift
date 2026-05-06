//
//  FileTranscriptionService.swift
//  mywisper
//
//  Created by Сергей Борисов on 06.05.2026.
//

import Foundation
import AVFoundation
import Combine

/// Singleton that owns long-running file transcription work.
/// Lives independently of any window so closing the UI doesn't cancel the job.
/// Uses a separate `WhisperTranscriber` from the dictation path and runs whisper-cli at
/// `.utility` QoS with half the cores so live dictation stays responsive.
///
/// All state mutations happen on the main queue (matching the rest of the codebase).
final class FileTranscriptionService: ObservableObject {
    static let shared = FileTranscriptionService()

    enum State: Equatable {
        case idle
        case preparing(sourceName: String)
        case transcribing(sourceName: String, progress: Double, elapsedSeconds: TimeInterval)
        case done(text: String, sourceURL: URL, sourceName: String, totalSeconds: TimeInterval)
        case failed(sourceName: String, message: String)
    }

    enum ServiceError: Error, LocalizedError {
        case alreadyRunning(currentName: String)
        case fileTooLong(durationSeconds: TimeInterval, max: TimeInterval)
        case whisperNotReady(hint: String)
        case cannotReadAudio(reason: String)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning(let name):
                return "Another file (\(name)) is being transcribed. Wait for it to finish or cancel it."
            case .fileTooLong(let dur, let max):
                return "File is too long: \(Self.format(dur)) (max \(Self.format(max))). Trim it and try again."
            case .whisperNotReady(let hint):
                return hint
            case .cannotReadAudio(let reason):
                return reason
            }
        }

        private static func format(_ s: TimeInterval) -> String {
            let total = Int(s.rounded())
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
    }

    static let maxDurationSeconds: TimeInterval = 60 * 60

    @Published private(set) var state: State = .idle

    /// Compact one-line status for the menu bar dropdown ("📄 podcast.mp3 — 47%").
    /// nil when idle, populated while preparing/transcribing, briefly for the latest done.
    @Published private(set) var menuBarStatus: String?

    private let extractor = AudioExtractor()
    private let transcriber = WhisperTranscriber()
    private var currentTask: Task<Void, Never>?
    private var currentProcess: Process?
    private var currentTempURL: URL?
    private var currentSourceName: String?
    private var startedAt: Date?
    private var elapsedTimer: Timer?

    private init() {}

    // MARK: - Public API

    /// Validates and starts a background transcription. Returns immediately.
    /// Throws if there's already work in flight, the file is too long, Whisper isn't ready,
    /// or the file can't be read.
    func start(sourceURL: URL, language: String) async -> Result<Void, ServiceError> {
        if case .preparing = state { return .failure(.alreadyRunning(currentName: currentSourceName ?? "another file")) }
        if case .transcribing = state { return .failure(.alreadyRunning(currentName: currentSourceName ?? "another file")) }

        // Validate Whisper readiness
        let modelPath = SettingsManager.shared.whisperModelPath
        if !FileManager.default.fileExists(atPath: modelPath) {
            return .failure(.whisperNotReady(hint: "Open Settings → General → Whisper Model and download or select a model."))
        }
        transcriber.loadModel(path: modelPath)
        transcriber.setLanguage(language)
        if !transcriber.isReady {
            return .failure(.whisperNotReady(hint: "Whisper isn't ready. Check the model and whisper-cli binary in Settings → General."))
        }

        // Validate duration up front
        let duration: TimeInterval
        do {
            let asset = AVURLAsset(url: sourceURL)
            let cmTime = try await asset.load(.duration)
            duration = CMTimeGetSeconds(cmTime)
            guard duration.isFinite, duration > 0 else {
                return .failure(.cannotReadAudio(reason: "Could not read the file's duration. Is it a real audio/video file?"))
            }
        } catch {
            return .failure(.cannotReadAudio(reason: "Could not read this file: \(error.localizedDescription)"))
        }

        if duration > Self.maxDurationSeconds {
            return .failure(.fileTooLong(durationSeconds: duration, max: Self.maxDurationSeconds))
        }

        // Kick off the background pipeline
        let sourceName = sourceURL.lastPathComponent
        currentSourceName = sourceName
        startedAt = Date()
        state = .preparing(sourceName: sourceName)
        menuBarStatus = "📄 \(sourceName) — preparing…"

        currentTask = Task(priority: .utility) { [weak self] in
            await self?.runPipeline(sourceURL: sourceURL, sourceName: sourceName)
        }

        return .success(())
    }

    /// Cancels in-flight work, deletes the temp WAV, and returns to idle.
    func cancel() {
        currentProcess?.terminate()
        currentProcess = nil

        currentTask?.cancel()
        currentTask = nil

        cleanupTemp()
        stopElapsedTimer()

        currentSourceName = nil
        startedAt = nil
        state = .idle
        menuBarStatus = nil
    }

    /// Clears the latest result so the view returns to the empty drop state.
    func clearLastResult() {
        if case .done = state {
            state = .idle
            menuBarStatus = nil
        } else if case .failed = state {
            state = .idle
            menuBarStatus = nil
        }
    }

    // MARK: - Pipeline

    private func runPipeline(sourceURL: URL, sourceName: String) async {
        // Step 1 — extract / convert to 16 kHz mono WAV
        let wavURL: URL
        do {
            wavURL = try await extractor.extractToWAV(from: sourceURL)
        } catch {
            await MainActor.run {
                self.state = .failed(sourceName: sourceName, message: error.localizedDescription)
                self.menuBarStatus = nil
                self.currentSourceName = nil
            }
            return
        }

        if Task.isCancelled { try? FileManager.default.removeItem(at: wavURL); return }

        currentTempURL = wavURL

        // Step 2 — transcribe with progress
        await MainActor.run {
            self.state = .transcribing(sourceName: sourceName, progress: 0, elapsedSeconds: 0)
            self.menuBarStatus = "📄 \(sourceName) — 0%"
            self.startElapsedTimer()
        }

        let cores = ProcessInfo.processInfo.activeProcessorCount
        let threads = max(2, cores / 2)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let process = transcriber.transcribe(
                audioFileURL: wavURL,
                threads: threads,
                qos: .utility,
                onProgress: { [weak self] progress in
                    guard let self = self else { return }
                    if case .transcribing(let name, _, _) = self.state {
                        let elapsed = self.startedAt.map { Date().timeIntervalSince($0) } ?? 0
                        self.state = .transcribing(sourceName: name, progress: progress, elapsedSeconds: elapsed)
                        self.menuBarStatus = "📄 \(name) — \(Int((progress * 100).rounded()))%"
                    }
                },
                completion: { [weak self] result in
                    guard let self = self else { cont.resume(); return }
                    self.handleTranscribeResult(result, sourceURL: sourceURL, sourceName: sourceName, wavURL: wavURL)
                    cont.resume()
                }
            )
            self.currentProcess = process
        }
    }

    private func handleTranscribeResult(
        _ result: Result<String, Error>,
        sourceURL: URL,
        sourceName: String,
        wavURL: URL
    ) {
        currentProcess = nil
        stopElapsedTimer()
        try? FileManager.default.removeItem(at: wavURL)
        currentTempURL = nil

        switch result {
        case .success(let text):
            let total = startedAt.map { Date().timeIntervalSince($0) } ?? 0
            state = .done(text: text, sourceURL: sourceURL, sourceName: sourceName, totalSeconds: total)
            menuBarStatus = "📄 \(sourceName) — done"
            currentSourceName = nil
            startedAt = nil

            // Notify so the user sees it even if the window is closed.
            NotificationManager.shared.notifyFileTranscribed(
                sourceName: sourceName,
                preview: String(text.prefix(120))
            )
        case .failure(let error):
            if let werr = error as? WhisperTranscriberError, case .cancelled = werr {
                // User cancelled — clean idle state, no error UI.
                state = .idle
                menuBarStatus = nil
            } else {
                state = .failed(sourceName: sourceName, message: error.localizedDescription)
                menuBarStatus = nil
            }
            currentSourceName = nil
            startedAt = nil
        }
    }

    // MARK: - Helpers

    private func startElapsedTimer() {
        stopElapsedTimer()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if case .transcribing(let name, let progress, _) = self.state,
                   let started = self.startedAt {
                    let elapsed = Date().timeIntervalSince(started)
                    self.state = .transcribing(sourceName: name, progress: progress, elapsedSeconds: elapsed)
                }
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func cleanupTemp() {
        if let url = currentTempURL {
            try? FileManager.default.removeItem(at: url)
            currentTempURL = nil
        }
    }
}

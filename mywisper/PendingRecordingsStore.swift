//
//  PendingRecordingsStore.swift
//  mywisper
//
//  Created by Сергей Борисов on 06.05.2026.
//

import Foundation

/// Manages on-disk persistence of recordings that failed to transcribe via the cloud engine.
/// Layout: `~/Library/Application Support/mywisper/pending/{uuid}.wav` + `{uuid}.json` sidecar.
class PendingRecordingsStore: ObservableObject {
    static let shared = PendingRecordingsStore()

    @Published private(set) var items: [PendingRecording] = []

    private let directory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("mywisper/pending", isDirectory: true)
    }()

    init() {
        ensureDirectoryExists()
        purgeOlderThan(days: 30)
        loadFromDisk()
    }

    // MARK: - Paths

    func audioURL(for recording: PendingRecording) -> URL {
        directory.appendingPathComponent("\(recording.id.uuidString).wav")
    }

    private func metadataURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Public API

    /// Copy an audio file from a temp location into pending/ and register a new entry.
    /// The source file is left in place (caller can keep using it for the in-flight request).
    @discardableResult
    func enqueue(
        audioFileURL: URL,
        language: String,
        prompt: String?,
        duration: TimeInterval
    ) -> PendingRecording? {
        ensureDirectoryExists()

        let recording = PendingRecording(
            durationSeconds: duration,
            language: language,
            prompt: prompt
        )

        let destAudio = audioURL(for: recording)

        do {
            if FileManager.default.fileExists(atPath: destAudio.path) {
                try FileManager.default.removeItem(at: destAudio)
            }
            try FileManager.default.copyItem(at: audioFileURL, to: destAudio)
        } catch {
            print("mywisper: PendingStore.enqueue copy failed: \(error.localizedDescription)")
            return nil
        }

        guard writeMetadata(recording) else {
            try? FileManager.default.removeItem(at: destAudio)
            return nil
        }

        DispatchQueue.main.async {
            self.items.append(recording)
        }
        return recording
    }

    func remove(_ id: UUID) {
        let audio = directory.appendingPathComponent("\(id.uuidString).wav")
        let meta = metadataURL(for: id)
        try? FileManager.default.removeItem(at: audio)
        try? FileManager.default.removeItem(at: meta)

        DispatchQueue.main.async {
            self.items.removeAll { $0.id == id }
        }
    }

    func markFailed(_ id: UUID, error: Error) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        var updated = items[idx]
        updated.lastError = error.localizedDescription
        updated.retryCount += 1
        _ = writeMetadata(updated)

        DispatchQueue.main.async {
            if let i = self.items.firstIndex(where: { $0.id == id }) {
                self.items[i] = updated
            }
        }
    }

    func recording(with id: UUID) -> PendingRecording? {
        items.first { $0.id == id }
    }

    // MARK: - Disk I/O

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func writeMetadata(_ recording: PendingRecording) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(recording)
            try data.write(to: metadataURL(for: recording.id), options: .atomic)
            return true
        } catch {
            print("mywisper: PendingStore.writeMetadata failed: \(error.localizedDescription)")
            return false
        }
    }

    private func loadFromDisk() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [PendingRecording] = []
        var seenIDs = Set<UUID>()

        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let recording = try? decoder.decode(PendingRecording.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            // Drop orphaned metadata if its audio is gone.
            let audio = directory.appendingPathComponent("\(recording.id.uuidString).wav")
            guard FileManager.default.fileExists(atPath: audio.path) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            seenIDs.insert(recording.id)
            loaded.append(recording)
        }

        // Drop orphaned audio (wav without metadata).
        for url in entries where url.pathExtension == "wav" {
            let stem = url.deletingPathExtension().lastPathComponent
            if let id = UUID(uuidString: stem), !seenIDs.contains(id) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        loaded.sort { $0.createdAt < $1.createdAt }
        self.items = loaded
    }

    private func purgeOlderThan(days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for url in entries {
            if let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               mtime < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

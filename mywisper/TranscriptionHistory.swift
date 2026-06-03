//
//  TranscriptionHistory.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import Foundation

struct TranscriptionRecord: Identifiable, Codable {
    let id: UUID
    let text: String
    let rawText: String?
    let date: Date
    let engine: String
    let language: String
    let durationSeconds: Double
    let aiProcessed: Bool
    let aiModel: String?
    /// Origin of the transcription. "file" for Transcribe-File results; nil/"mic" for live dictation.
    /// Optional so older saved records (without this key) still decode.
    let source: String?
    /// For file transcriptions, the source file name (e.g. "podcast.mp3").
    let sourceName: String?

    init(text: String, rawText: String? = nil, engine: String, language: String, durationSeconds: Double, aiProcessed: Bool = false, aiModel: String? = nil, source: String? = nil, sourceName: String? = nil) {
        self.id = UUID()
        self.text = text
        self.rawText = rawText
        self.date = Date()
        self.engine = engine
        self.language = language
        self.durationSeconds = durationSeconds
        self.aiProcessed = aiProcessed
        self.aiModel = aiModel
        self.source = source
        self.sourceName = sourceName
    }

    /// True when this came from the Transcribe-File flow.
    var isFile: Bool { source == "file" }
}

class TranscriptionHistory: ObservableObject {
    static let shared = TranscriptionHistory()

    @Published var records: [TranscriptionRecord] = []

    private let storageURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("mywisper")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init() {
        load()
    }

    // MARK: - Statistics

    /// Read-only usage statistics derived from the stored records.
    struct Stats {
        var totalTranscriptions: Int
        var totalWords: Int
        var totalAudioSeconds: Double
        /// Approximate time saved vs typing, assuming an average typing speed of 40 WPM
        /// minus the time actually spent dictating.
        var timeSavedSeconds: Double
    }

    var stats: Stats {
        let totalWords = records.reduce(0) { sum, record in
            sum + record.text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        }
        let totalAudio = records.reduce(0.0) { $0 + $1.durationSeconds }
        // 40 words/min typing → 1.5s per word. Subtract the dictation time to estimate savings.
        let typingSeconds = Double(totalWords) * 1.5
        let saved = max(0, typingSeconds - totalAudio)
        return Stats(
            totalTranscriptions: records.count,
            totalWords: totalWords,
            totalAudioSeconds: totalAudio,
            timeSavedSeconds: saved
        )
    }

    func add(_ record: TranscriptionRecord) {
        records.insert(record, at: 0)
        save()
    }

    func delete(at offsets: IndexSet) {
        records.remove(atOffsets: offsets)
        save()
    }

    func delete(id: UUID) {
        records.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        records.removeAll()
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("mywisper: Failed to save history: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            records = try JSONDecoder().decode([TranscriptionRecord].self, from: data)
        } catch {
            print("mywisper: Failed to load history: \(error)")
        }
    }
}

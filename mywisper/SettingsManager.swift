//
//  SettingsManager.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import Foundation
import AppKit

enum TranscriptionEngine: String, CaseIterable {
    case apple = "apple"
    case whisper = "whisper"
    case cloud = "cloud"

    var displayName: String {
        switch self {
        case .apple: return "Apple Speech (fast, lower quality)"
        case .whisper: return "Whisper (better quality, slower)"
        case .cloud: return "Cloud (OpenAI Whisper API)"
        }
    }
}

struct DictionaryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var wrong: String
    var correct: String

    init(wrong: String, correct: String) {
        self.id = UUID()
        self.wrong = wrong
        self.correct = correct
    }
}

struct AIPromptPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var prompt: String

    init(name: String, prompt: String) {
        self.id = UUID()
        self.name = name
        self.prompt = prompt
    }

    static let builtIn: [AIPromptPreset] = [
        AIPromptPreset(
            name: "Clean Up",
            prompt: "You are a text editor. Clean up the following dictated text: fix grammar, punctuation, and formatting. Keep the original meaning and language. Return only the cleaned text, nothing else."
        ),
        AIPromptPreset(
            name: "Translate to English",
            prompt: "You are a translator. The user speaks in any language. Translate the following text into natural, fluent English. Return only the translation, nothing else."
        ),
        AIPromptPreset(
            name: "Translate to Russian",
            prompt: "You are a translator. The user speaks in any language. Translate the following text into natural, fluent Russian. Return only the translation, nothing else."
        ),
        AIPromptPreset(
            name: "Developer Style",
            prompt: "You are a technical writer. Rewrite the following dictated text in a clear, concise developer style suitable for code comments, commit messages, or technical documentation. Fix grammar and formatting. Return only the rewritten text, nothing else."
        ),
        AIPromptPreset(
            name: "Warm & Friendly",
            prompt: "You are a writing assistant. Rewrite the following dictated text in a warm, friendly, conversational tone. Fix grammar and make it sound natural and approachable. Return only the rewritten text, nothing else."
        ),
        AIPromptPreset(
            name: "Formal Business",
            prompt: "You are a business writing assistant. Rewrite the following dictated text in a professional, formal business tone suitable for emails and documents. Fix grammar and formatting. Return only the rewritten text, nothing else."
        ),
    ]
}

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var engine: TranscriptionEngine {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "transcriptionEngine") }
    }

    @Published var whisperModelPath: String {
        didSet { UserDefaults.standard.set(whisperModelPath, forKey: "whisperModelPath") }
    }

    @Published var selectedLanguage: String {
        didSet { UserDefaults.standard.set(selectedLanguage, forKey: "selectedLanguage") }
    }

    @Published var hotkeyDoubleTapInterval: Double {
        didSet { UserDefaults.standard.set(hotkeyDoubleTapInterval, forKey: "hotkeyDoubleTapInterval") }
    }

    @Published var useDoubleTapFn: Bool {
        didSet { UserDefaults.standard.set(useDoubleTapFn, forKey: "useDoubleTapFn") }
    }

    @Published var useCustomHotkey: Bool {
        didSet { UserDefaults.standard.set(useCustomHotkey, forKey: "useCustomHotkey") }
    }

    @Published var customHotkeyKeyCode: UInt16 {
        didSet { UserDefaults.standard.set(Int(customHotkeyKeyCode), forKey: "customHotkeyKeyCode") }
    }

    @Published var customHotkeyModifiers: NSEvent.ModifierFlags {
        didSet { UserDefaults.standard.set(Int(customHotkeyModifiers.rawValue), forKey: "customHotkeyModifiers") }
    }

    // MARK: - AI Processing Settings

    @Published var aiProcessingEnabled: Bool {
        didSet { UserDefaults.standard.set(aiProcessingEnabled, forKey: "aiProcessingEnabled") }
    }

    @Published var openAIKey: String {
        didSet { UserDefaults.standard.set(openAIKey, forKey: "openAIKey") }
    }

    @Published var openAIModel: String {
        didSet { UserDefaults.standard.set(openAIModel, forKey: "openAIModel") }
    }

    @Published var aiSystemPrompt: String {
        didSet { UserDefaults.standard.set(aiSystemPrompt, forKey: "aiSystemPrompt") }
    }

    @Published var aiPresets: [AIPromptPreset] {
        didSet {
            if let data = try? JSONEncoder().encode(aiPresets) {
                UserDefaults.standard.set(data, forKey: "aiPresets")
            }
        }
    }

    // MARK: - AI Toggle Hotkey

    @Published var useAIToggleHotkey: Bool {
        didSet { UserDefaults.standard.set(useAIToggleHotkey, forKey: "useAIToggleHotkey") }
    }

    @Published var aiToggleHotkeyKeyCode: UInt16 {
        didSet { UserDefaults.standard.set(Int(aiToggleHotkeyKeyCode), forKey: "aiToggleHotkeyKeyCode") }
    }

    @Published var aiToggleHotkeyModifiers: NSEvent.ModifierFlags {
        didSet { UserDefaults.standard.set(Int(aiToggleHotkeyModifiers.rawValue), forKey: "aiToggleHotkeyModifiers") }
    }

    var aiToggleHotkeyDisplayString: String {
        HotkeyManager.hotkeyDisplayString(modifiers: aiToggleHotkeyModifiers, keyCode: aiToggleHotkeyKeyCode)
    }

    // MARK: - Cancel Hotkey

    @Published var cancelHotkeyKeyCode: UInt16 {
        didSet { UserDefaults.standard.set(Int(cancelHotkeyKeyCode), forKey: "cancelHotkeyKeyCode") }
    }

    var cancelHotkeyDisplayString: String {
        HotkeyManager.keyCodeToString(cancelHotkeyKeyCode)
    }

    // MARK: - Custom Dictionary

    @Published var customDictionaryEnabled: Bool {
        didSet { UserDefaults.standard.set(customDictionaryEnabled, forKey: "customDictionaryEnabled") }
    }

    @Published var customDictionary: [DictionaryEntry] {
        didSet {
            if let data = try? JSONEncoder().encode(customDictionary) {
                UserDefaults.standard.set(data, forKey: "customDictionary")
            }
        }
    }

    // MARK: - Vocabulary Terms (smart single-word dictionary)

    @Published var vocabularyTerms: [String] {
        didSet {
            if let data = try? JSONEncoder().encode(vocabularyTerms) {
                UserDefaults.standard.set(data, forKey: "vocabularyTerms")
            }
        }
    }

    @Published var selectedPresetId: UUID? {
        didSet {
            if let id = selectedPresetId {
                UserDefaults.standard.set(id.uuidString, forKey: "selectedPresetId")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedPresetId")
            }
        }
    }

    static let availableModels = [
        "gpt-4o",
        "gpt-4o-mini",
        "gpt-4-turbo",
        "gpt-3.5-turbo",
    ]

    var customHotkeyDisplayString: String {
        HotkeyManager.hotkeyDisplayString(modifiers: customHotkeyModifiers, keyCode: customHotkeyKeyCode)
    }

    init() {
        let engineRaw = UserDefaults.standard.string(forKey: "transcriptionEngine") ?? "apple"
        self.engine = TranscriptionEngine(rawValue: engineRaw) ?? .apple
        self.whisperModelPath = UserDefaults.standard.string(forKey: "whisperModelPath") ?? ""
        self.selectedLanguage = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "en-US"

        let interval = UserDefaults.standard.double(forKey: "hotkeyDoubleTapInterval")
        self.hotkeyDoubleTapInterval = interval > 0 ? interval : 0.4

        self.useDoubleTapFn = UserDefaults.standard.object(forKey: "useDoubleTapFn") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "useDoubleTapFn")

        // Custom hotkey: default to ⌃⌥Space, enabled by default
        self.useCustomHotkey = UserDefaults.standard.object(forKey: "useCustomHotkey") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "useCustomHotkey")

        let storedKeyCode = UserDefaults.standard.integer(forKey: "customHotkeyKeyCode")
        self.customHotkeyKeyCode = storedKeyCode > 0 ? UInt16(storedKeyCode) : 49 // 49 = Space

        let storedMods = UserDefaults.standard.integer(forKey: "customHotkeyModifiers")
        if storedMods > 0 {
            self.customHotkeyModifiers = NSEvent.ModifierFlags(rawValue: UInt(storedMods))
        } else {
            self.customHotkeyModifiers = [.control, .option]
        }

        // AI Toggle Hotkey: default to ⌃⌥A, disabled by default
        self.useAIToggleHotkey = UserDefaults.standard.bool(forKey: "useAIToggleHotkey")

        let storedAIKeyCode = UserDefaults.standard.integer(forKey: "aiToggleHotkeyKeyCode")
        self.aiToggleHotkeyKeyCode = storedAIKeyCode > 0 ? UInt16(storedAIKeyCode) : 0 // 0 = A

        let storedAIMods = UserDefaults.standard.integer(forKey: "aiToggleHotkeyModifiers")
        if storedAIMods > 0 {
            self.aiToggleHotkeyModifiers = NSEvent.ModifierFlags(rawValue: UInt(storedAIMods))
        } else {
            self.aiToggleHotkeyModifiers = [.control, .option]
        }

        // Cancel hotkey: default to Escape (keyCode 53)
        let storedCancelKeyCode = UserDefaults.standard.integer(forKey: "cancelHotkeyKeyCode")
        self.cancelHotkeyKeyCode = storedCancelKeyCode > 0 ? UInt16(storedCancelKeyCode) : 53

        // AI Processing
        self.aiProcessingEnabled = UserDefaults.standard.bool(forKey: "aiProcessingEnabled")
        self.openAIKey = UserDefaults.standard.string(forKey: "openAIKey") ?? ""
        self.openAIModel = UserDefaults.standard.string(forKey: "openAIModel") ?? "gpt-4o-mini"
        self.aiSystemPrompt = UserDefaults.standard.string(forKey: "aiSystemPrompt")
            ?? AIPromptPreset.builtIn[0].prompt

        if let presetsData = UserDefaults.standard.data(forKey: "aiPresets"),
           let decoded = try? JSONDecoder().decode([AIPromptPreset].self, from: presetsData) {
            self.aiPresets = decoded
        } else {
            self.aiPresets = AIPromptPreset.builtIn
        }

        // Custom Dictionary
        self.customDictionaryEnabled = UserDefaults.standard.object(forKey: "customDictionaryEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "customDictionaryEnabled")

        if let dictData = UserDefaults.standard.data(forKey: "customDictionary"),
           let decoded = try? JSONDecoder().decode([DictionaryEntry].self, from: dictData) {
            self.customDictionary = decoded
        } else {
            self.customDictionary = []
        }

        if let vocabData = UserDefaults.standard.data(forKey: "vocabularyTerms"),
           let decoded = try? JSONDecoder().decode([String].self, from: vocabData) {
            self.vocabularyTerms = decoded
        } else {
            self.vocabularyTerms = []
        }

        if let idString = UserDefaults.standard.string(forKey: "selectedPresetId"),
           let id = UUID(uuidString: idString) {
            self.selectedPresetId = id
        } else {
            self.selectedPresetId = nil
        }

        // Auto-fix model path: if empty OR points to non-existent file, find a valid model
        let modelFileExists = !whisperModelPath.isEmpty && FileManager.default.fileExists(atPath: whisperModelPath)
        if !modelFileExists {
            if !whisperModelPath.isEmpty {
                print("mywisper: Stored model path no longer exists: \(whisperModelPath)")
            }
            var foundPath: String?
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let copiedModel = appSupport.appendingPathComponent("mywisper/models/ggml-tiny.bin")
            if FileManager.default.fileExists(atPath: copiedModel.path) {
                foundPath = copiedModel.path
                print("mywisper: Auto-selected model: \(copiedModel.path)")
            } else if let bundledModel = Bundle.main.url(forResource: "ggml-tiny", withExtension: "bin") {
                foundPath = bundledModel.path
                print("mywisper: Auto-selected bundled model: \(bundledModel.path)")
            }
            if let path = foundPath {
                whisperModelPath = path
                // didSet doesn't fire during init(), so save manually
                UserDefaults.standard.set(path, forKey: "whisperModelPath")
            }
            // Default to whisper engine on fresh install if model is available
            if !whisperModelPath.isEmpty && UserDefaults.standard.string(forKey: "transcriptionEngine") == nil {
                engine = .whisper
                UserDefaults.standard.set(engine.rawValue, forKey: "transcriptionEngine")
            }
        }
    }

    // MARK: - Dictionary Helpers

    func dictionaryPromptAddendum() -> String? {
        let active = customDictionary.filter { !$0.wrong.isEmpty && !$0.correct.isEmpty }
        guard customDictionaryEnabled && !active.isEmpty else { return nil }
        let lines = active.map { "- \"\($0.wrong)\" → \"\($0.correct)\"" }.joined(separator: "\n")
        return "\n\nIMPORTANT: The following words/phrases are often misrecognized by speech recognition. Always use the correct spelling when you encounter these or similar-sounding words:\n\(lines)"
    }

    func applyDictionaryReplacements(to text: String) -> String {
        guard customDictionaryEnabled else { return text }
        var result = text
        for entry in customDictionary where !entry.wrong.isEmpty && !entry.correct.isEmpty {
            result = result.replacingOccurrences(
                of: entry.wrong,
                with: entry.correct,
                options: [.caseInsensitive]
            )
        }
        return result
    }

    // MARK: - Vocabulary Helpers

    /// Build vocabulary hint string for OpenAI Whisper API prompt parameter
    func vocabularyPromptHint() -> String? {
        guard customDictionaryEnabled else { return nil }
        let terms = vocabularyTerms.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: ", ")
    }

    /// Build vocabulary addendum for AI system prompt
    func vocabularyAIAddendum() -> String? {
        guard customDictionaryEnabled else { return nil }
        let terms = vocabularyTerms.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        let list = terms.map { "- \($0)" }.joined(separator: "\n")
        return "\n\nCRITICAL VOCABULARY CORRECTIONS: The following are correct technical terms. Speech recognition often badly misspells these. You MUST find any word that sounds even remotely similar to these terms and replace it with the correct spelling. For example, \"dogploy\", \"dock ploy\", \"dog ploy\", \"dokploy\" should all become \"Dokploy\". Be aggressive — if a word could possibly be a mangled version of one of these terms, use the correct spelling:\n\(list)"
    }

    /// Scans known locations for Whisper .bin model files
    func findAvailableModels() -> [(name: String, path: String)] {
        var models: [(name: String, path: String)] = []
        let fm = FileManager.default

        // Scan mywisper's own models directory
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let ownModelDir = appSupport.appendingPathComponent("mywisper/models")
        scanDirectory(ownModelDir, into: &models)

        // Scan app bundle Resources for bundled models
        if let resourceURL = Bundle.main.resourceURL {
            scanDirectory(resourceURL, into: &models)
        }

        // Scan SuperWhisper models
        let superwhisperDir = appSupport.appendingPathComponent("superwhisper")
        scanDirectory(superwhisperDir, into: &models)

        // Scan whisper.cpp models directory
        let home = fm.homeDirectoryForCurrentUser
        let whisperCppModels = home.appendingPathComponent("Downloads/whisper.cpp/models")
        scanDirectory(whisperCppModels, into: &models)

        return models
    }

    private func scanDirectory(_ dir: URL, into models: inout [(name: String, path: String)]) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "bin" && file.lastPathComponent.hasPrefix("ggml") {
            let name = file.deletingPathExtension().lastPathComponent
            if !models.contains(where: { $0.path == file.path }) {
                models.append((name: name, path: file.path))
            }
        }
    }
}

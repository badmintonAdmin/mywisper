//
//  SettingsManager.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import Foundation
import AppKit
import ServiceManagement

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

/// A speech-recognition language option. `code` is the canonical locale identifier we store
/// in `selectedLanguage` (e.g. "en-US"); "auto" is a sentinel meaning "let the engine detect".
struct DictationLanguage: Identifiable, Equatable {
    let code: String
    let displayName: String
    var id: String { code }

    /// True for the special "detect language automatically" option.
    var isAuto: Bool { code == DictationLanguage.autoCode }

    static let autoCode = "auto"

    /// ISO-639-1 code passed to Whisper / OpenAI (first 2 chars of the locale), or "auto".
    var isoCode: String {
        isAuto ? DictationLanguage.autoCode : String(code.prefix(2)).lowercased()
    }

    /// The full list shown in the menu bar and Settings. Defined in one place so all three
    /// engines and both UIs stay in sync.
    static let all: [DictationLanguage] = [
        DictationLanguage(code: autoCode, displayName: "Auto (detect)"),
        DictationLanguage(code: "en-US", displayName: "English"),
        DictationLanguage(code: "ru-RU", displayName: "Русский"),
        DictationLanguage(code: "es-ES", displayName: "Español"),
        DictationLanguage(code: "fr-FR", displayName: "Français"),
        DictationLanguage(code: "de-DE", displayName: "Deutsch"),
        DictationLanguage(code: "it-IT", displayName: "Italiano"),
        DictationLanguage(code: "pt-PT", displayName: "Português"),
        DictationLanguage(code: "nl-NL", displayName: "Nederlands"),
        DictationLanguage(code: "pl-PL", displayName: "Polski"),
        DictationLanguage(code: "uk-UA", displayName: "Українська"),
        DictationLanguage(code: "zh-CN", displayName: "中文"),
        DictationLanguage(code: "ja-JP", displayName: "日本語"),
        DictationLanguage(code: "ko-KR", displayName: "한국어"),
    ]

    static func displayName(for code: String) -> String {
        all.first(where: { $0.code == code })?.displayName ?? code
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

    /// True for the six bundled presets (matched by name). Built-ins can't be deleted.
    var isBuiltIn: Bool {
        AIPromptPreset.builtIn.contains(where: { $0.name == name })
    }

    /// Human-friendly one-line description of what each built-in mode does, shown in Settings.
    /// Falls back to a generic line for custom modes.
    var humanDescription: String {
        AIPromptPreset.descriptions[name] ?? "Custom mode — your own instructions for the AI."
    }

    /// One-liners keyed by built-in preset name.
    static let descriptions: [String: String] = [
        "Clean Up": "Fixes grammar, punctuation and formatting. Keeps your words and language.",
        "Translate to English": "Translates whatever you say into natural, fluent English.",
        "Translate to Russian": "Translates whatever you say into natural, fluent Russian.",
        "Developer Style": "Tightens text into clear developer prose for commits, comments and docs.",
        "Warm & Friendly": "Rewrites your text in a warm, friendly, conversational tone.",
        "Formal Business": "Rewrites your text in a polished, professional business tone.",
    ]

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

    /// Unique ID of the preferred audio input device, or "" to use the system default.
    /// Matches `AVCaptureDevice.uniqueID`.
    @Published var selectedInputDeviceID: String {
        didSet { UserDefaults.standard.set(selectedInputDeviceID, forKey: "selectedInputDeviceID") }
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

    // MARK: - Cycle AI Mode Hotkey

    @Published var useCycleModeHotkey: Bool {
        didSet { UserDefaults.standard.set(useCycleModeHotkey, forKey: "useCycleModeHotkey") }
    }

    @Published var cycleModeHotkeyKeyCode: UInt16 {
        didSet { UserDefaults.standard.set(Int(cycleModeHotkeyKeyCode), forKey: "cycleModeHotkeyKeyCode") }
    }

    @Published var cycleModeHotkeyModifiers: NSEvent.ModifierFlags {
        didSet { UserDefaults.standard.set(Int(cycleModeHotkeyModifiers.rawValue), forKey: "cycleModeHotkeyModifiers") }
    }

    var cycleModeHotkeyDisplayString: String {
        HotkeyManager.hotkeyDisplayString(modifiers: cycleModeHotkeyModifiers, keyCode: cycleModeHotkeyKeyCode)
    }

    // MARK: - Cancel Hotkey

    @Published var cancelHotkeyKeyCode: UInt16 {
        didSet { UserDefaults.standard.set(Int(cancelHotkeyKeyCode), forKey: "cancelHotkeyKeyCode") }
    }

    var cancelHotkeyDisplayString: String {
        HotkeyManager.keyCodeToString(cancelHotkeyKeyCode)
    }

    // MARK: - Onboarding

    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    /// Play a light sound cue when recording starts, so it's clear the hotkey fired.
    @Published var playStartSound: Bool {
        didSet { UserDefaults.standard.set(playStartSound, forKey: "playStartSound") }
    }

    /// Selectable cue sounds: built-in macOS system sounds + custom bundled mp3s,
    /// discovered at runtime. See `SoundLibrary`.
    static var availableSounds: [String] { SoundLibrary.allCueSounds }

    /// Which sound to play for the start/finish cue.
    @Published var selectedSoundName: String {
        didSet { UserDefaults.standard.set(selectedSoundName, forKey: "selectedSoundName") }
    }

    /// Show a persistent Dock icon (regular app) so mywisper is always reachable even when the
    /// menu-bar icon is hidden behind the notch. AppDelegate applies the activation policy.
    @Published var showDockIcon: Bool {
        didSet { UserDefaults.standard.set(showDockIcon, forKey: "showDockIcon") }
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

    /// Selectable OpenAI models for AI post-processing, cheap → most capable.
    /// gpt-4o-mini is the default (plenty for cleanup); the GPT-5 family is available for
    /// users who want higher quality.
    static let availableModels = [
        "gpt-4o-mini",
        "gpt-4o",
        "gpt-4-turbo",
        "gpt-5-mini",
        "gpt-5",
        "gpt-5.4-mini",
        "gpt-5.5",
        "gpt-5.5-pro",
    ]

    var customHotkeyDisplayString: String {
        HotkeyManager.hotkeyDisplayString(modifiers: customHotkeyModifiers, keyCode: customHotkeyKeyCode)
    }

    init() {
        let engineRaw = UserDefaults.standard.string(forKey: "transcriptionEngine") ?? "apple"
        self.engine = TranscriptionEngine(rawValue: engineRaw) ?? .apple
        self.whisperModelPath = UserDefaults.standard.string(forKey: "whisperModelPath") ?? ""
        self.selectedLanguage = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "en-US"
        self.selectedInputDeviceID = UserDefaults.standard.string(forKey: "selectedInputDeviceID") ?? ""

        let interval = UserDefaults.standard.double(forKey: "hotkeyDoubleTapInterval")
        self.hotkeyDoubleTapInterval = interval > 0 ? interval : 0.4

        self.useDoubleTapFn = UserDefaults.standard.object(forKey: "useDoubleTapFn") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "useDoubleTapFn")

        // Custom hotkey: default to ⌥Space, enabled by default
        self.useCustomHotkey = UserDefaults.standard.object(forKey: "useCustomHotkey") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "useCustomHotkey")

        let storedKeyCode = UserDefaults.standard.integer(forKey: "customHotkeyKeyCode")
        self.customHotkeyKeyCode = storedKeyCode > 0 ? UInt16(storedKeyCode) : 49 // 49 = Space

        let storedMods = UserDefaults.standard.integer(forKey: "customHotkeyModifiers")
        if storedMods > 0 {
            self.customHotkeyModifiers = NSEvent.ModifierFlags(rawValue: UInt(storedMods))
        } else {
            self.customHotkeyModifiers = [.option]
        }

        // AI Toggle Hotkey: default to ⌃⌥A, enabled by default (user-overridable in Settings)
        self.useAIToggleHotkey = UserDefaults.standard.object(forKey: "useAIToggleHotkey") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "useAIToggleHotkey")

        let storedAIKeyCode = UserDefaults.standard.integer(forKey: "aiToggleHotkeyKeyCode")
        self.aiToggleHotkeyKeyCode = storedAIKeyCode > 0 ? UInt16(storedAIKeyCode) : 0 // 0 = A

        let storedAIMods = UserDefaults.standard.integer(forKey: "aiToggleHotkeyModifiers")
        if storedAIMods > 0 {
            self.aiToggleHotkeyModifiers = NSEvent.ModifierFlags(rawValue: UInt(storedAIMods))
        } else {
            self.aiToggleHotkeyModifiers = [.control, .option]
        }

        // Cycle AI Mode Hotkey: default to ⌃⌥M, enabled by default (user-overridable in Settings)
        self.useCycleModeHotkey = UserDefaults.standard.object(forKey: "useCycleModeHotkey") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "useCycleModeHotkey")

        let storedCycleKeyCode = UserDefaults.standard.integer(forKey: "cycleModeHotkeyKeyCode")
        self.cycleModeHotkeyKeyCode = storedCycleKeyCode > 0 ? UInt16(storedCycleKeyCode) : 46 // 46 = M

        let storedCycleMods = UserDefaults.standard.integer(forKey: "cycleModeHotkeyModifiers")
        if storedCycleMods > 0 {
            self.cycleModeHotkeyModifiers = NSEvent.ModifierFlags(rawValue: UInt(storedCycleMods))
        } else {
            self.cycleModeHotkeyModifiers = [.control, .option]
        }

        // Cancel hotkey: default to Escape (keyCode 53)
        let storedCancelKeyCode = UserDefaults.standard.integer(forKey: "cancelHotkeyKeyCode")
        self.cancelHotkeyKeyCode = storedCancelKeyCode > 0 ? UInt16(storedCancelKeyCode) : 53

        // Onboarding
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        // Default ON when never set.
        self.playStartSound = UserDefaults.standard.object(forKey: "playStartSound") == nil
            ? true : UserDefaults.standard.bool(forKey: "playStartSound")
        self.selectedSoundName = UserDefaults.standard.string(forKey: "selectedSoundName") ?? "Pop"
        self.showDockIcon = UserDefaults.standard.bool(forKey: "showDockIcon")

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

        // One-time migration: move anyone still on the previous default record hotkey (⌃⌥Space)
        // to the new default (⌥Space). Users who picked their own hotkey are left untouched.
        if !UserDefaults.standard.bool(forKey: "didMigrateHotkeyOptSpace") {
            let oldDefault = NSEvent.ModifierFlags([.control, .option]).rawValue
            if customHotkeyKeyCode == 49 && customHotkeyModifiers.rawValue == oldDefault {
                customHotkeyModifiers = [.option]   // didSet persists it
            }
            UserDefaults.standard.set(true, forKey: "didMigrateHotkeyOptSpace")
        }
    }

    // MARK: - AI Mode Helpers

    /// Advance to the next AI mode preset (wrapping around), update the active system prompt,
    /// and return the newly-selected preset. No-op returning nil if there are no presets.
    @discardableResult
    func cycleToNextPreset() -> AIPromptPreset? {
        guard !aiPresets.isEmpty else { return nil }
        let nextIndex: Int
        if let id = selectedPresetId,
           let current = aiPresets.firstIndex(where: { $0.id == id }) {
            nextIndex = (current + 1) % aiPresets.count
        } else {
            // No active preset (or a detached custom prompt) — start at the first.
            nextIndex = 0
        }
        let next = aiPresets[nextIndex]
        selectedPresetId = next.id
        aiSystemPrompt = next.prompt
        return next
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

// MARK: - Launch at Login

/// Thin wrapper around `SMAppService.mainApp` (macOS 13+). SMAppService is the source of
/// truth; `isEnabled` simply mirrors its `.status` so a SwiftUI Toggle can bind to it.
class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published var isEnabled: Bool = false

    private init() {
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Register/unregister the login item and re-sync `isEnabled` from the new status.
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            print("mywisper: Launch-at-login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        refresh()
    }
}

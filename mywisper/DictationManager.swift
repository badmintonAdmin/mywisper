//
//  DictationManager.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import Foundation
import SwiftUI
import AVFoundation
import AppKit
import Combine

class DictationManager: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var currentTranscription = ""
    @Published var selectedLanguage: String {
        didSet {
            UserDefaults.standard.set(selectedLanguage, forKey: "selectedLanguage")
            settings.selectedLanguage = selectedLanguage
            speechTranscriber.setLanguage(selectedLanguage)
            whisperTranscriber.setLanguage(selectedLanguage)
        }
    }

    private let audioRecorder = AudioRecorder()
    private let speechTranscriber = SpeechTranscriber()
    private let whisperTranscriber = WhisperTranscriber()
    private let openAIService = OpenAIService.shared
    private let cloudWhisperService = CloudWhisperService.shared
    private let textPaster = TextPaster()
    private let hotkeyManager = HotkeyManager()
    private let settings = SettingsManager.shared
    private let history = TranscriptionHistory.shared
    var recordingPanel: RecordingPanel?
    private var permissionsChecked = false
    private var previousApp: NSRunningApplication?
    private var settingsCancellables = Set<AnyCancellable>()
    private var recordingStartTime: Date?

    init() {
        self.selectedLanguage = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "en-US"

        // Startup diagnostics
        print("mywisper: === STARTUP DIAGNOSTICS ===")
        print("mywisper: Engine: \(settings.engine.rawValue)")
        print("mywisper: Model path: \(settings.whisperModelPath.isEmpty ? "(empty)" : settings.whisperModelPath)")
        print("mywisper: Model exists: \(settings.whisperModelPath.isEmpty ? false : FileManager.default.fileExists(atPath: settings.whisperModelPath))")
        print("mywisper: Binary path: \(whisperTranscriber.binaryPath)")
        print("mywisper: Binary exists: \(FileManager.default.fileExists(atPath: whisperTranscriber.binaryPath))")
        print("mywisper: Accessibility: \(AXIsProcessTrusted())")
        print("mywisper: Bundle path: \(Bundle.main.bundlePath)")
        print("mywisper: ===========================")

        checkPermissions()

        hotkeyManager.onToggle = { [weak self] in
            self?.toggleRecording()
        }

        hotkeyManager.onToggleAI = { [weak self] in
            guard let self = self else { return }
            self.settings.aiProcessingEnabled.toggle()
            let status = self.settings.aiProcessingEnabled ? "ON" : "OFF"
            print("mywisper: AI processing toggled \(status) via hotkey")
        }

        // Wire audio level metering to overlay (runs at 30fps)
        audioRecorder.onAudioLevel = { [weak self] level in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.recordingPanel?.state.audioLevel = level
                if let start = self.recordingStartTime {
                    self.recordingPanel?.state.elapsedSeconds = Date().timeIntervalSince(start)
                }
            }
        }

        // Apply custom hotkey settings
        applyHotkeySettings()
        hotkeyManager.register()

        speechTranscriber.configure(language: selectedLanguage)

        // Load Whisper model if engine is set to whisper
        if settings.engine == .whisper && !settings.whisperModelPath.isEmpty {
            whisperTranscriber.loadModel(path: settings.whisperModelPath)
            whisperTranscriber.setLanguage(selectedLanguage)
            print("mywisper: Whisper ready: \(whisperTranscriber.isReady)")
        }

        // Watch for settings changes
        settings.$engine.sink { [weak self] engine in
            guard let self = self else { return }
            if engine == .whisper && !self.settings.whisperModelPath.isEmpty {
                self.whisperTranscriber.loadModel(path: self.settings.whisperModelPath)
                self.whisperTranscriber.setLanguage(self.selectedLanguage)
            }
        }.store(in: &settingsCancellables)

        settings.$whisperModelPath.sink { [weak self] path in
            guard let self = self else { return }
            if self.settings.engine == .whisper && !path.isEmpty {
                self.whisperTranscriber.loadModel(path: path)
                self.whisperTranscriber.setLanguage(self.selectedLanguage)
            }
        }.store(in: &settingsCancellables)

        settings.$hotkeyDoubleTapInterval.sink { [weak self] interval in
            self?.hotkeyManager.doubleTapInterval = interval
        }.store(in: &settingsCancellables)

        settings.$useDoubleTapFn.sink { [weak self] enabled in
            guard let self = self else { return }
            if enabled {
                self.hotkeyManager.register()
            } else {
                self.hotkeyManager.unregisterFnOnly()
            }
        }.store(in: &settingsCancellables)

        settings.$useCustomHotkey.sink { [weak self] _ in
            self?.applyHotkeySettings()
            self?.hotkeyManager.register()
        }.store(in: &settingsCancellables)

        settings.$customHotkeyKeyCode.sink { [weak self] _ in
            self?.applyHotkeySettings()
            self?.hotkeyManager.register()
        }.store(in: &settingsCancellables)

        settings.$customHotkeyModifiers.sink { [weak self] _ in
            self?.applyHotkeySettings()
            self?.hotkeyManager.register()
        }.store(in: &settingsCancellables)

        settings.$useAIToggleHotkey.sink { [weak self] _ in
            self?.applyHotkeySettings()
            self?.hotkeyManager.register()
        }.store(in: &settingsCancellables)

        settings.$aiToggleHotkeyKeyCode.sink { [weak self] _ in
            self?.applyHotkeySettings()
            self?.hotkeyManager.register()
        }.store(in: &settingsCancellables)

        settings.$aiToggleHotkeyModifiers.sink { [weak self] _ in
            self?.applyHotkeySettings()
            self?.hotkeyManager.register()
        }.store(in: &settingsCancellables)
    }

    func toggleRecording() {
        if isRecording {
            stopRecordingAndTranscribe()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording && !isTranscribing else { return }

        // Check engine readiness
        switch settings.engine {
        case .apple:
            if !speechTranscriber.isReady {
                speechTranscriber.configure(language: selectedLanguage)
                guard speechTranscriber.isReady else {
                    print("mywisper: Speech recognizer not available")
                    currentTranscription = "Error: Speech recognizer not available"
                    return
                }
            }
        case .whisper:
            if !whisperTranscriber.isReady {
                if !settings.whisperModelPath.isEmpty && !FileManager.default.fileExists(atPath: settings.whisperModelPath) {
                    print("mywisper: Model file missing at \(settings.whisperModelPath), searching for alternative...")
                    let models = settings.findAvailableModels()
                    if let first = models.first {
                        settings.whisperModelPath = first.path
                        print("mywisper: Auto-switched to model: \(first.path)")
                    }
                }
                whisperTranscriber.loadModel(path: settings.whisperModelPath)
                guard whisperTranscriber.isReady else {
                    print("mywisper: Whisper not ready. Model: \(settings.whisperModelPath), Binary: \(whisperTranscriber.binaryPath)")
                    currentTranscription = "Error: Whisper not ready. Check model & binary in Settings."
                    return
                }
            }
        case .cloud:
            guard !settings.openAIKey.isEmpty else {
                print("mywisper: Cloud Whisper requires OpenAI API key")
                currentTranscription = "Error: OpenAI API key required. Set it in Settings → AI Processing."
                return
            }
        }

        // Don't block recording for accessibility — it's only needed for paste
        if !TextPaster.checkAccessibilityPermission() {
            print("mywisper: Accessibility not granted — will copy to clipboard but can't auto-paste")
        }

        currentTranscription = ""

        // Remember which app was active so we can paste back into it
        previousApp = NSWorkspace.shared.frontmostApplication
        print("mywisper: Saved previous app: \(previousApp?.localizedName ?? "none")")

        do {
            try audioRecorder.startRecording()
        } catch {
            print("mywisper: Failed to start recording: \(error.localizedDescription)")
            currentTranscription = "Error: Failed to start recording. Check microphone permission."
            return
        }

        isRecording = true
        recordingStartTime = Date()
        showOverlay(status: "Recording...")
        recordingPanel?.state.isRecording = true
        recordingPanel?.state.isTranscribing = false
        recordingPanel?.state.elapsedSeconds = 0
    }

    private func stopRecordingAndTranscribe() {
        guard isRecording else { return }

        let audioFileURL = audioRecorder.stopRecordingAndGetURL()
        isRecording = false
        isTranscribing = true
        recordingPanel?.state.statusText = "Transcribing..."
        recordingPanel?.state.isRecording = false
        recordingPanel?.state.isTranscribing = true

        guard let url = audioFileURL else {
            print("mywisper: No audio file")
            isTranscribing = false
            hideOverlay()
            return
        }

        let startTime = Date()
        let engineName: String
        switch settings.engine {
        case .apple: engineName = "Apple Speech"
        case .whisper: engineName = "Whisper"
        case .cloud: engineName = "Cloud Whisper"
        }
        print("mywisper: Using \(engineName) engine")

        let completionHandler: (Result<String, Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let elapsed = Date().timeIntervalSince(startTime)
                print("mywisper: Transcription done in \(String(format: "%.1f", elapsed))s (\(engineName))")

                switch result {
                case .success(let rawText):
                    if !rawText.isEmpty && self.settings.aiProcessingEnabled && !self.settings.openAIKey.isEmpty {
                        // AI post-processing step
                        self.recordingPanel?.state.statusText = "AI Processing..."
                        self.recordingPanel?.state.isTranscribing = true
                        print("mywisper: Sending to AI for post-processing...")

                        var effectivePrompt = self.settings.aiSystemPrompt
                        if let addendum = self.settings.vocabularyAIAddendum() {
                            effectivePrompt += addendum
                        }
                        if let addendum = self.settings.dictionaryPromptAddendum() {
                            effectivePrompt += addendum
                        }

                        self.openAIService.process(
                            text: rawText,
                            apiKey: self.settings.openAIKey,
                            model: self.settings.openAIModel,
                            systemPrompt: effectivePrompt
                        ) { [weak self] aiResult in
                            DispatchQueue.main.async {
                                guard let self = self else { return }
                                self.isTranscribing = false
                                self.hideOverlay()

                                let finalText: String
                                switch aiResult {
                                case .success(let processed):
                                    finalText = processed
                                    print("mywisper: AI processing complete")
                                case .failure(let error):
                                    // Fall back to raw text on AI error
                                    finalText = rawText
                                    print("mywisper: AI processing failed, using raw text: \(error.localizedDescription)")
                                }

                                self.currentTranscription = finalText
                                let recordingDuration = self.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
                                let record = TranscriptionRecord(
                                    text: finalText,
                                    rawText: rawText,
                                    engine: self.settings.engine.rawValue,
                                    language: self.selectedLanguage,
                                    durationSeconds: recordingDuration,
                                    aiProcessed: true,
                                    aiModel: self.settings.openAIModel
                                )
                                self.history.add(record)
                                self.textPaster.paste(text: finalText, previousApp: self.previousApp)
                            }
                        }
                    } else {
                        // No AI processing — apply dictionary replacements and paste
                        let processedText = self.settings.applyDictionaryReplacements(to: rawText)
                        self.isTranscribing = false
                        self.currentTranscription = processedText
                        self.hideOverlay()

                        if !processedText.isEmpty {
                            let recordingDuration = self.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
                            let record = TranscriptionRecord(
                                text: processedText,
                                rawText: processedText != rawText ? rawText : nil,
                                engine: self.settings.engine.rawValue,
                                language: self.selectedLanguage,
                                durationSeconds: recordingDuration
                            )
                            self.history.add(record)
                            self.textPaster.paste(text: processedText, previousApp: self.previousApp)
                        }
                    }
                case .failure(let error):
                    print("mywisper: Error: \(error)")
                    self.isTranscribing = false
                    self.currentTranscription = "Error: \(error.localizedDescription)"
                    self.hideOverlay()
                }
            }
        }

        switch settings.engine {
        case .apple:
            speechTranscriber.transcribe(audioFileURL: url, completion: completionHandler)
        case .whisper:
            whisperTranscriber.transcribe(audioFileURL: url, completion: completionHandler)
        case .cloud:
            cloudWhisperService.transcribe(
                audioFileURL: url,
                apiKey: settings.openAIKey,
                language: selectedLanguage,
                prompt: settings.vocabularyPromptHint(),
                completion: completionHandler
            )
        }
    }

    private func showOverlay(status: String) {
        if recordingPanel == nil {
            recordingPanel = RecordingPanel()
            recordingPanel?.state.onStop = { [weak self] in
                self?.toggleRecording()
            }
        }
        recordingPanel?.state.statusText = status
        recordingPanel?.show()
    }

    private func hideOverlay() {
        recordingPanel?.hide()
    }

    private func applyHotkeySettings() {
        hotkeyManager.useCustomHotkey = settings.useCustomHotkey
        hotkeyManager.customHotkeyKeyCode = settings.customHotkeyKeyCode
        hotkeyManager.customHotkeyModifiers = settings.customHotkeyModifiers
        hotkeyManager.doubleTapInterval = settings.hotkeyDoubleTapInterval
        hotkeyManager.useAIToggleHotkey = settings.useAIToggleHotkey
        hotkeyManager.aiToggleHotkeyKeyCode = settings.aiToggleHotkeyKeyCode
        hotkeyManager.aiToggleHotkeyModifiers = settings.aiToggleHotkeyModifiers
    }

    private func checkPermissions() {
        guard !permissionsChecked else { return }
        permissionsChecked = true

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { print("mywisper: Microphone permission denied") }
        }

        // Log accessibility status but don't show dialog on startup
        let accessOK = AXIsProcessTrusted()
        print("mywisper: Accessibility permission: \(accessOK ? "granted" : "not granted")")
        if !accessOK {
            print("mywisper: Global hotkeys and auto-paste won't work. Grant in System Settings > Privacy & Security > Accessibility")
        }
    }

    deinit {
        hotkeyManager.unregister()
    }
}

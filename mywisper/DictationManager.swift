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
    let pendingStore = PendingRecordingsStore.shared
    private let notificationManager = NotificationManager.shared
    var recordingPanel: RecordingPanel?
    private var permissionsChecked = false
    private var previousApp: NSRunningApplication?
    private var settingsCancellables = Set<AnyCancellable>()
    private var recordingStartTime: Date?
    private var isCancelled = false
    /// ID of the in-flight pending recording (cloud only); nil if no cloud request is active.
    private var currentPendingID: UUID?

    init() {
        self.selectedLanguage = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "en-US"

        checkPermissions()

        hotkeyManager.onToggle = { [weak self] in
            self?.toggleRecording()
        }

        hotkeyManager.onToggleAI = { [weak self] in
            guard let self = self else { return }
            self.settings.aiProcessingEnabled.toggle()
        }

        hotkeyManager.onCancel = { [weak self] in
            self?.cancelOperation()
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

        // The Settings UI writes settings.selectedLanguage directly; mirror it into our own
        // selectedLanguage (whose didSet re-configures all three engines). Guard against the
        // echo from our own didSet write to avoid a redundant reconfigure loop.
        settings.$selectedLanguage.sink { [weak self] language in
            guard let self = self, self.selectedLanguage != language else { return }
            self.selectedLanguage = language
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

        settings.$cancelHotkeyKeyCode.sink { [weak self] _ in
            self?.applyHotkeySettings()
            self?.hotkeyManager.register()
        }.store(in: &settingsCancellables)

        // Retry from system notification
        NotificationCenter.default.publisher(for: .retryPendingRequested)
            .sink { [weak self] note in
                guard let id = note.userInfo?["id"] as? UUID else { return }
                DispatchQueue.main.async { self?.retryPendingByID(id) }
            }
            .store(in: &settingsCancellables)
    }

    func toggleRecording() {
        if isRecording {
            stopRecordingAndTranscribe()
        } else {
            startRecording()
        }
    }

    /// Abort the current recording or transcription without pasting
    func cancelOperation() {
        guard isRecording || isTranscribing else { return }

        if isRecording {
            // Stop recording, discard audio
            _ = audioRecorder.stopRecordingAndGetURL()
            isRecording = false
            print("mywisper: Recording cancelled by user")
        }

        // Discard any pending audio that we copied to the persistent store before sending —
        // the user explicitly aborted, so don't keep it on disk.
        if let id = currentPendingID {
            pendingStore.remove(id)
            currentPendingID = nil
        }

        // Terminate the local whisper-cli process if one is running so a user cancel
        // actually stops the work (cloud/apple in-flight calls complete but their result
        // is ignored because isCancelled is set below).
        whisperTranscriber.cancel()

        // Mark transcription as cancelled (in-flight network/whisper calls will complete
        // but their result will be ignored because isTranscribing is already false)
        isTranscribing = false
        isCancelled = true
        currentTranscription = ""
        recordingStartTime = nil
        recordingPanel?.state.progress = nil
        hotkeyManager.isOperationActive = false
        hideOverlay()
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
                    showTransientStatus("Speech recognizer not available")
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
                        showTransientStatus("Selected Whisper model was missing — switched to \(first.name)", duration: 4.0)
                    }
                }
                whisperTranscriber.loadModel(path: settings.whisperModelPath)
                guard whisperTranscriber.isReady else {
                    print("mywisper: Whisper not ready. Model: \(settings.whisperModelPath), Binary: \(whisperTranscriber.binaryPath)")
                    showTransientStatus("Whisper not ready — check model & binary in Settings")
                    return
                }
            }
        case .cloud:
            guard !settings.openAIKey.isEmpty else {
                print("mywisper: Cloud Whisper requires OpenAI API key")
                showTransientStatus("OpenAI API key required — set it in Settings → AI Processing")
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

        do {
            try audioRecorder.startRecording()
        } catch {
            print("mywisper: Failed to start recording: \(error.localizedDescription)")
            showTransientStatus("Failed to start recording — check microphone permission")
            return
        }

        isRecording = true
        isCancelled = false
        recordingStartTime = Date()
        hotkeyManager.isOperationActive = true
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
        recordingPanel?.state.statusText = settings.engine == .cloud ? "Cloud Transcribing..." : "Transcribing..."
        recordingPanel?.state.isRecording = false
        recordingPanel?.state.isTranscribing = true
        // Local Whisper reports a real percentage; other engines stay indeterminate.
        recordingPanel?.state.progress = settings.engine == .whisper ? 0 : nil

        guard let url = audioFileURL else {
            isTranscribing = false
            hideOverlay()
            if audioRecorder.lastRecordingWasTooShort {
                print("mywisper: Recording too short")
                showTransientStatus("Recording too short")
            } else {
                print("mywisper: No audio file")
                showTransientStatus("Recording failed")
            }
            return
        }

        let completionHandler = makeTranscriptionCompletionHandler()

        switch settings.engine {
        case .apple:
            speechTranscriber.transcribe(audioFileURL: url, completion: completionHandler)
        case .whisper:
            whisperTranscriber.transcribe(
                audioFileURL: url,
                onProgress: { [weak self] fraction in
                    guard let self = self, self.isTranscribing, !self.isCancelled else { return }
                    self.recordingPanel?.state.progress = fraction
                },
                completion: completionHandler
            )
        case .cloud:
            // Persist audio BEFORE sending so it survives a crash and can be retried.
            let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
            guard let pending = pendingStore.enqueue(
                audioFileURL: url,
                language: selectedLanguage,
                prompt: settings.vocabularyPromptHint(),
                duration: duration
            ) else {
                print("mywisper: Failed to persist audio for cloud transcription")
                completionHandler(.failure(CloudWhisperError.cannotReadAudioFile))
                return
            }
            currentPendingID = pending.id
            transcribeCloudWithRetry(pending: pending, completion: completionHandler)
        }
    }

    /// Transcribe via cloud Whisper with automatic retries on transient errors.
    /// On final failure, leaves audio in `pendingStore` and posts a system notification.
    private func transcribeCloudWithRetry(
        pending: PendingRecording,
        attempt: Int = 1,
        maxAttempts: Int = 3,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let audioURL = pendingStore.audioURL(for: pending)
        cloudWhisperService.transcribe(
            audioFileURL: audioURL,
            apiKey: settings.openAIKey,
            language: pending.language,
            prompt: pending.prompt
        ) { [weak self] result in
            guard let self = self else { return }
            // Hop to main before touching isCancelled / currentPendingID so all reads and
            // writes of that shared state happen on a single thread (no cross-thread races).
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    self.pendingStore.remove(pending.id)
                    if self.currentPendingID == pending.id { self.currentPendingID = nil }
                    completion(.success(text))

                case .failure(let error):
                    let canRetry = CloudWhisperService.isTransient(error)
                        && attempt < maxAttempts
                        && !self.isCancelled

                    if canRetry {
                        let delay: TimeInterval = attempt == 1 ? 2.0 : 5.0
                        self.recordingPanel?.state.statusText = "Retrying \(attempt + 1)/\(maxAttempts)..."
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            guard !self.isCancelled else { return }
                            self.transcribeCloudWithRetry(
                                pending: pending,
                                attempt: attempt + 1,
                                maxAttempts: maxAttempts,
                                completion: completion
                            )
                        }
                    } else {
                        self.pendingStore.markFailed(pending.id, error: error)
                        if !self.isCancelled {
                            self.notificationManager.notifyTranscriptionFailed(pending: pending, error: error)
                        }
                        if self.currentPendingID == pending.id { self.currentPendingID = nil }
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    /// Builds the shared completion handler used for both initial transcription and retries.
    /// Handles AI post-processing, history, paste, and overlay teardown.
    private func makeTranscriptionCompletionHandler() -> (Result<String, Error>) -> Void {
        return { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }

                // If the operation was cancelled, discard the result
                guard !self.isCancelled else { return }

                switch result {
                case .success(let rawText):
                    if !rawText.isEmpty && self.settings.aiProcessingEnabled && !self.settings.openAIKey.isEmpty {
                        // AI post-processing step
                        self.recordingPanel?.state.statusText = "AI Processing..."
                        self.recordingPanel?.state.isTranscribing = true
                        // AI has no real percentage — fall back to the indeterminate indicator.
                        self.recordingPanel?.state.progress = nil

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
                                guard let self = self, !self.isCancelled else { return }
                                self.isTranscribing = false
                                self.hideOverlay()

                                let finalText: String
                                switch aiResult {
                                case .success(let processed):
                                    finalText = processed
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
                                self.pasteAndNotify(finalText)
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
                            self.pasteAndNotify(processedText)
                        } else {
                            // Empty result (e.g. silence) — tell the user instead of doing nothing.
                            self.showTransientStatus("No speech detected")
                        }
                    }
                case .failure(let error):
                    print("mywisper: Error: \(error)")
                    self.isTranscribing = false
                    self.hideOverlay()
                    self.surfaceTranscriptionError(error)
                }
            }
        }
    }

    /// Public entry point for retrying a previously failed cloud transcription
    /// (called from the menu bar or a notification action).
    func retryPending(_ pending: PendingRecording) {
        guard !isRecording, !isTranscribing else { return }

        // Capture whatever app is currently frontmost. For menu bar retries this is still
        // the user's editor; for notification retries this becomes mywisper itself, so
        // paste won't go anywhere useful — but the text always lands in the clipboard.
        previousApp = NSWorkspace.shared.frontmostApplication
        recordingStartTime = Date().addingTimeInterval(-pending.durationSeconds)
        isCancelled = false
        currentPendingID = pending.id
        isTranscribing = true
        currentTranscription = ""
        showOverlay(status: "Retrying upload...")
        recordingPanel?.state.isRecording = false
        recordingPanel?.state.isTranscribing = true
        recordingPanel?.state.progress = nil
        hotkeyManager.isOperationActive = true

        transcribeCloudWithRetry(pending: pending, completion: makeTranscriptionCompletionHandler())
    }

    fileprivate func retryPendingByID(_ id: UUID) {
        guard let pending = pendingStore.recording(with: id) else { return }
        retryPending(pending)
    }

    /// Token used to invalidate a pending auto-hide when a newer transient status arrives.
    private var transientStatusToken = 0

    /// Show a brief, self-dismissing status message in the floating panel (e.g. "No speech
    /// detected", "Recording too short", "Copied to clipboard…"). Used as the app's single
    /// lightweight error/notice surface so messages no longer vanish into `currentTranscription`.
    /// Must be called on the main thread.
    private func showTransientStatus(_ message: String, duration: TimeInterval = 2.5) {
        // Don't stomp on an active recording/transcription overlay.
        guard !isRecording && !isTranscribing else {
            currentTranscription = message
            return
        }

        currentTranscription = message

        if recordingPanel == nil {
            recordingPanel = RecordingPanel()
            recordingPanel?.state.onStop = { [weak self] in
                self?.toggleRecording()
            }
            recordingPanel?.state.onCancel = { [weak self] in
                self?.cancelOperation()
            }
        }
        recordingPanel?.state.isRecording = false
        recordingPanel?.state.isTranscribing = false
        recordingPanel?.state.statusText = message
        recordingPanel?.show()

        transientStatusToken += 1
        let token = transientStatusToken
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self else { return }
            // Only hide if no newer status/recording superseded this one.
            guard self.transientStatusToken == token,
                  !self.isRecording, !self.isTranscribing else { return }
            self.recordingPanel?.hide()
        }
    }

    /// Paste the text and, if Accessibility wasn't granted (so we could only copy), surface a
    /// brief notice telling the user to press Cmd+V. Must be called on the main thread.
    private func pasteAndNotify(_ text: String) {
        let result = textPaster.paste(text: text, previousApp: previousApp)
        if result == .copiedToClipboardOnly {
            showTransientStatus("Copied to clipboard — press ⌘V (grant Accessibility to auto-paste)", duration: 4.0)
        }
    }

    /// Undo the most recent auto-paste: restore the prior clipboard and (when Accessibility is
    /// granted) simulate Cmd+Z into the focused app. Best-effort and safe (no-op if nothing to
    /// undo). Re-activates the app we pasted into so Cmd+Z lands in the right place.
    func undoLastPaste() {
        guard !isRecording, !isTranscribing else { return }

        if let app = previousApp {
            app.activate(options: .activateIgnoringOtherApps)
        }

        // Give the target app a moment to become active before simulating Cmd+Z.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            switch self.textPaster.undoLastPaste() {
            case .nothingToUndo:
                self.showTransientStatus("Nothing to undo")
            case .undone:
                self.showTransientStatus("Undid last paste")
            case .clipboardRestoredOnly:
                self.showTransientStatus("Clipboard restored — press ⌘Z to remove text (grant Accessibility)", duration: 4.0)
            }
        }
    }

    /// True when there is a paste that can be undone (drives the menu item's enabled state).
    var canUndoLastPaste: Bool {
        textPaster.lastPastedText != nil
    }

    /// Surface a transcription failure. Maps known cases (no speech, cancellation) to friendly
    /// transient statuses; everything else shows the error's description.
    /// Must be called on the main thread.
    private func surfaceTranscriptionError(_ error: Error) {
        if let werr = error as? WhisperTranscriberError {
            switch werr {
            case .cancelled:
                // User cancel — no error UI.
                return
            case .noSpeechDetected:
                showTransientStatus("No speech detected")
                return
            default:
                break
            }
        }
        showTransientStatus(error.localizedDescription, duration: 4.0)
    }

    private func showOverlay(status: String) {
        if recordingPanel == nil {
            recordingPanel = RecordingPanel()
            recordingPanel?.state.onStop = { [weak self] in
                self?.toggleRecording()
            }
            recordingPanel?.state.onCancel = { [weak self] in
                self?.cancelOperation()
            }
        }
        recordingPanel?.state.statusText = status
        recordingPanel?.show()
    }

    private func hideOverlay() {
        recordingPanel?.hide()
        hotkeyManager.isOperationActive = false
    }

    private func applyHotkeySettings() {
        hotkeyManager.useCustomHotkey = settings.useCustomHotkey
        hotkeyManager.customHotkeyKeyCode = settings.customHotkeyKeyCode
        hotkeyManager.customHotkeyModifiers = settings.customHotkeyModifiers
        hotkeyManager.doubleTapInterval = settings.hotkeyDoubleTapInterval
        hotkeyManager.useAIToggleHotkey = settings.useAIToggleHotkey
        hotkeyManager.aiToggleHotkeyKeyCode = settings.aiToggleHotkeyKeyCode
        hotkeyManager.aiToggleHotkeyModifiers = settings.aiToggleHotkeyModifiers
        hotkeyManager.cancelHotkeyKeyCode = settings.cancelHotkeyKeyCode
    }

    private func checkPermissions() {
        guard !permissionsChecked else { return }
        permissionsChecked = true

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    deinit {
        hotkeyManager.unregister()
    }
}

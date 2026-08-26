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
            // Engines never see the "system" sentinel — hand them the concrete language.
            let resolved = DictationLanguage.resolved(selectedLanguage)
            speechTranscriber.setLanguage(resolved)
            speechConfiguredLanguage = resolved
            whisperTranscriber.setLanguage(resolved)
            prewarmFastEngineIfNeeded()
            prewarmTranslationIfNeeded()
        }
    }

    private let audioRecorder = AudioRecorder()
    private let liveController = LiveTranscriptionController()
    /// True while the current recording is being captured via the live (segmented) path rather
    /// than the classic single-file AudioRecorder. Decided at record start and read on stop/cancel.
    private var usingLiveSession = false
    private let speechTranscriber = SpeechTranscriber()
    private let whisperTranscriber = WhisperTranscriber()
    /// True while the current recording streams into the fast Apple engine (SpeechAnalyzer,
    /// macOS 26+). Decided at record start and read on stop/cancel.
    private var usingFastSession = false
    /// True while the current recording streams into the classic SFSpeechRecognizer instead —
    /// the Apple Live engine's fallback for languages SpeechAnalyzer doesn't cover (Russian,
    /// Auto) and for macOS < 26. Still streaming, so stopping is near-instant too.
    private var usingLegacyLiveSession = false
    /// In-flight fast-session start; stop awaits it so a quick tap can't outrun session setup.
    private var fastStartTask: Task<Void, Never>?
    /// Normalized language codes the fast engine supports on this machine (empty before the
    /// async fetch completes and on macOS < 26). Russian is NOT in this set as of macOS 26.5.
    private var fastSupportedCodes: Set<String> = []
    /// FastSpeechService, stored untyped because the class is @available(macOS 26.0+) and this
    /// property must exist on 13.3. Created eagerly in init on supported systems.
    private var _fastSpeech: Any?
    @available(macOS 26.0, *)
    private var fastSpeech: FastSpeechService {
        if let existing = _fastSpeech as? FastSpeechService { return existing }
        let service = FastSpeechService()
        _fastSpeech = service
        return service
    }
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
    /// Highest normalized audio level (0...1) seen during the current recording. Used to detect a
    /// dead/silent mic: Whisper hallucinates stock phrases ("Субтитры делал…", "you you", random
    /// languages) on near-silent input, so we skip transcription entirely when nothing was heard.
    private var maxAudioLevel: Float = 0
    /// Below this peak level the whole recording is treated as silence (≈ -47 dBFS). Deliberately
    /// low so only a genuinely dead mic trips it — real speech, even quiet, peaks well above this.
    private let silenceLevelThreshold: Float = 0.06
    /// ID of the in-flight pending recording (cloud only); nil if no cloud request is active.
    private var currentPendingID: UUID?

    // MARK: Session triggers (push-to-talk, second language, translate)

    /// Which trigger started a session: the primary hotkey, the second-language key
    /// (right ⌥) or the translate key (right ⌘).
    enum DictationTrigger { case primary, secondary, translate }

    /// A press shorter than this is a tap (hands-free session, tap again to stop);
    /// held longer it's push-to-talk (release finishes the dictation).
    static let pushToTalkHoldThreshold: TimeInterval = 0.35
    /// A bare-modifier session younger than this is cancelled when another key is
    /// typed — the user was using ⌥/⌘ as a modifier, not dictating.
    static let modifierInterruptWindow: TimeInterval = 0.6

    private var activeTrigger: DictationTrigger?
    private var triggerDownAt: Date?
    /// The language THIS session dictates in (the second-language key overrides the
    /// global pick for one session, without touching Settings).
    private var sessionLanguage: String = "en-US"
    /// Whether this session's transcript is translated before pasting.
    private var sessionTranslate = false

    /// Keeps macOS from App-Napping the process mid-session (throttled TimelineView
    /// clocks and timers glitch the first session after hours idle). Held from record
    /// start until the text is delivered or the session dies.
    private let activity = ActivityAssertion(reason: "Dictation session")

    init() {
        self.selectedLanguage = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "en-US"

        checkPermissions()

        hotkeyManager.onToggle = { [weak self] in
            self?.toggleRecording()
        }

        // Push-to-talk gestures: the custom hotkey and the two bare-modifier triggers
        // report down/up; the gesture (hold vs tap) is resolved here.
        hotkeyManager.onPrimaryDown = { [weak self] in self?.handleTriggerDown(.primary) }
        hotkeyManager.onPrimaryUp = { [weak self] in self?.handleTriggerUp(.primary) }
        hotkeyManager.onSecondaryDown = { [weak self] in self?.handleTriggerDown(.secondary) }
        hotkeyManager.onSecondaryUp = { [weak self] in self?.handleTriggerUp(.secondary) }
        hotkeyManager.onTranslateDown = { [weak self] in self?.handleTriggerDown(.translate) }
        hotkeyManager.onTranslateUp = { [weak self] in self?.handleTriggerUp(.translate) }
        hotkeyManager.onModifierTriggerInterrupted = { [weak self] in
            self?.handleModifierTriggerInterrupted()
        }

        hotkeyManager.onToggleAI = { [weak self] in
            self?.toggleAIProcessing()
        }

        hotkeyManager.onCycleMode = { [weak self] in
            self?.cycleAIMode()
        }

        hotkeyManager.onCancel = { [weak self] in
            self?.cancelOperation()
        }

        // Wire audio level metering to overlay (runs at 30fps). Both the classic and live
        // recorders feed the same handler; only one is active at a time.
        audioRecorder.onAudioLevel = { [weak self] level in
            self?.handleAudioLevel(level)
        }
        liveController.onAudioLevel = { [weak self] level in
            self?.handleAudioLevel(level)
        }
        // Surface live segment progress as the "⚡N" badge in the recording overlay.
        liveController.onSegmentCompleted = { [weak self] done in
            self?.recordingPanel?.state.liveSegmentsDone = done
        }

        // Apply custom hotkey settings
        applyHotkeySettings()
        hotkeyManager.register()

        speechTranscriber.configure(language: DictationLanguage.resolved(selectedLanguage))
        speechConfiguredLanguage = DictationLanguage.resolved(selectedLanguage)

        // Fast Apple engine (macOS 26+): learn which languages it supports, then prewarm so the
        // first hotkey press is instant. The supported set also gates the per-session fallback.
        if #available(macOS 26.0, *) {
            _fastSpeech = FastSpeechService()
            fetchFastSupportedCodes()
        }

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
            if engine == .fastApple {
                // sink fires before `settings.engine` is updated; prewarm for the new value.
                self.prewarmFastEngineIfNeeded(engineOverride: engine)
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

        settings.$useCycleModeHotkey.sink { [weak self] _ in
            self?.applyHotkeySettings()
            self?.hotkeyManager.register()
        }.store(in: &settingsCancellables)

        settings.$cycleModeHotkeyKeyCode.sink { [weak self] _ in
            self?.applyHotkeySettings()
            self?.hotkeyManager.register()
        }.store(in: &settingsCancellables)

        settings.$cycleModeHotkeyModifiers.sink { [weak self] _ in
            self?.applyHotkeySettings()
            self?.hotkeyManager.register()
        }.store(in: &settingsCancellables)

        settings.$cancelHotkeyKeyCode.sink { [weak self] _ in
            self?.applyHotkeySettings()
            self?.hotkeyManager.register()
        }.store(in: &settingsCancellables)

        // Second language: arm/disarm its trigger and keep its engine prewarmed so the
        // right-⌥ press answers as fast as the primary.
        settings.$secondLanguage.sink { [weak self] language in
            guard let self = self else { return }
            self.hotkeyManager.secondaryTriggerEnabled = !language.isEmpty
            if !language.isEmpty, self.settings.engine == .fastApple {
                if #available(macOS 26.0, *) {
                    let service = self.fastSpeech
                    Task { [fastSupportedCodes = self.fastSupportedCodes] in
                        guard fastSupportedCodes.contains(language.lowercased()) else { return }
                        await service.prewarm(languageCode: language)
                    }
                }
            }
        }.store(in: &settingsCancellables)

        // Translation target: arm/disarm the translate trigger and prewarm the pair.
        settings.$translationTargetLanguage.sink { [weak self] target in
            guard let self = self else { return }
            self.hotkeyManager.translateTriggerEnabled = {
                if #available(macOS 26.0, *) { return !target.isEmpty }
                return false
            }()
            self.prewarmTranslationIfNeeded(target: target)
        }.store(in: &settingsCancellables)

        // The user switched the Mac's language: re-resolve System/Auto and re-prewarm so
        // the next dictation routes to the right recognizers without an app relaunch.
        NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let system = DictationLanguage.resolvedSystemCode()
                // The notification also fires for region/time-format changes; nothing to do
                // unless the resolved system LANGUAGE actually moved.
                guard system != self.lastSystemLanguageCode else { return }
                self.lastSystemLanguageCode = system
                DebugLog.log("system locale changed → system language now \(system)")
                // Eagerly reconfigure the classic recognizer for the new language: macOS
                // reloads speech assets after a language switch, and the first sessions can
                // come back empty while it settles — give it the head start now, not on
                // the user's first press.
                if !self.isRecording && !self.isTranscribing,
                   self.selectedLanguage == DictationLanguage.systemCode || self.selectedLanguage == DictationLanguage.autoCode {
                    self.speechTranscriber.configure(language: system)
                    self.speechConfiguredLanguage = system
                }
                self.prewarmFastEngineIfNeeded()
                self.prewarmTranslationIfNeeded()
            }
            .store(in: &settingsCancellables)

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

    // MARK: Trigger gestures

    /// A trigger was pressed. While idle it starts a session in that trigger's language
    /// (and translate mode); while recording, any trigger press finishes the session —
    /// that's both the hands-free "tap again" and the second press of a toggle.
    func handleTriggerDown(_ trigger: DictationTrigger) {
        guard !isTranscribing else { return }
        if isRecording {
            stopRecordingAndTranscribe()
            return
        }

        let language: String
        var translate = false
        switch trigger {
        case .primary:
            language = selectedLanguage
        case .secondary:
            guard !settings.secondLanguage.isEmpty else { return }
            language = settings.secondLanguage
        case .translate:
            guard settings.translationActive else { return }
            language = selectedLanguage
            translate = true
        }
        activeTrigger = trigger
        triggerDownAt = Date()
        startRecording(language: language, translate: translate)
    }

    /// The trigger was released. If it was held past the threshold this was
    /// push-to-talk: finish and paste. A quick tap leaves the session running
    /// hands-free (the next press stops it).
    func handleTriggerUp(_ trigger: DictationTrigger) {
        guard isRecording, trigger == activeTrigger, settings.pushToTalkEnabled else { return }
        guard let down = triggerDownAt else { return }
        if Date().timeIntervalSince(down) >= Self.pushToTalkHoldThreshold {
            stopRecordingAndTranscribe()
        }
    }

    /// Another key was typed while a bare-modifier trigger (right ⌥/⌘) was held. A
    /// session that young wasn't dictation — the user is typing with the modifier —
    /// so cancel it; an established session ignores stray keys.
    func handleModifierTriggerInterrupted() {
        guard isRecording,
              let trigger = activeTrigger, trigger != .primary,
              let down = triggerDownAt,
              Date().timeIntervalSince(down) < Self.modifierInterruptWindow
        else { return }
        cancelOperation()
    }

    /// Abort the current recording or transcription without pasting
    func cancelOperation() {
        guard isRecording || isTranscribing else { return }

        if usingDualSession {
            if #available(macOS 26.0, *) {
                let service = fastSpeech
                Task { await service.cancel() }
            }
            speechTranscriber.cancelLiveSession()
            usingDualSession = false
            dualPlan = nil
            resetDualKillState()
            if isRecording { print("mywisper: Recording cancelled by user") }
            isRecording = false
        } else if usingFastSession {
            if #available(macOS 26.0, *) {
                let service = fastSpeech
                Task { await service.cancel() }
            }
            usingFastSession = false
            if isRecording { print("mywisper: Recording cancelled by user") }
            isRecording = false
        } else if usingLegacyLiveSession {
            speechTranscriber.cancelLiveSession()
            usingLegacyLiveSession = false
            if isRecording { print("mywisper: Recording cancelled by user") }
            isRecording = false
        } else if usingLiveSession {
            // Tears down recording and any in-flight segment Whisper process; safe whether we were
            // still recording or already transcribing the tail.
            liveController.cancel()
            usingLiveSession = false
            if isRecording { print("mywisper: Recording cancelled by user") }
            isRecording = false
        } else if isRecording {
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
        activity.release()
        hideOverlay()
    }

    /// Timestamp of the last mic level, feeding the dead-microphone watchdog.
    private var lastLevelAt = Date()
    /// Fires while recording; marks the mic dead when levels stop arriving for 0.6s
    /// (the island visuals turn amber — a dead microphone must look different from silence).
    private var micWatchdogTimer: Timer?

    /// Shared overlay meter update for whichever recorder is active. Smooths the headline
    /// level with a fast attack / slow release and appends to the waveform history with a
    /// light EMA against the previous bar (calms per-tick jitter without dulling speech).
    private func handleAudioLevel(_ level: Float) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.maxAudioLevel = max(self.maxAudioLevel, level)
            self.lastLevelAt = Date()
            if let state = self.recordingPanel?.state {
                state.audioLevel = max(level, state.audioLevel * 0.88)
                state.levelHistory.removeFirst()
                let lastBar = state.levelHistory.last ?? 0
                state.levelHistory.append(0.6 * level + 0.4 * lastBar)
                state.isAudioAlive = true
            }
            if let start = self.recordingStartTime {
                self.recordingPanel?.state.elapsedSeconds = Date().timeIntervalSince(start)
            }
        }
    }

    private func startMicWatchdog() {
        micWatchdogTimer?.invalidate()
        micWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            guard self.isRecording else {
                timer.invalidate()
                self.micWatchdogTimer = nil
                return
            }
            if Date().timeIntervalSince(self.lastLevelAt) > 0.6 {
                self.recordingPanel?.state.isAudioAlive = false
            }
        }
    }

    /// Live (segmented) transcription only applies to the local Whisper engine and only when the
    /// user has it enabled and the model is ready. Every other case uses the classic single-file path.
    private var shouldUseLiveSession: Bool {
        settings.engine == .whisper && settings.liveTranscriptionEnabled && whisperTranscriber.isReady
    }

    /// SpeechAnalyzer's launch language list, used until the live fetch lands. Routing must
    /// never depend on an async call having completed: after a reinstall the fetch once came
    /// back empty and every session silently degraded to a single-language English path —
    /// Russian dictation just vanished.
    private static let fastBaselineCodes: Set<String> = [
        "en-us", "en-gb", "en-au", "en-ca", "en-in", "en-ie", "en-nz", "en-sg", "en-za",
        "de-de", "de-at", "de-ch", "es-es", "es-mx", "es-us", "es-cl",
        "fr-fr", "fr-ca", "fr-be", "fr-ch", "it-it", "it-ch",
        "ja-jp", "ko-kr", "pt-br", "pt-pt", "zh-cn", "zh-tw", "zh-hk", "yue-cn",
    ]

    /// Fetch the live supported set, retrying while the system answers empty (seen right
    /// after a reinstall). Until it lands, `fastUsable` runs on the baseline list.
    private func fetchFastSupportedCodes(attempt: Int = 0) {
        if #available(macOS 26.0, *) {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let codes = await FastSpeechService.supportedLanguageCodes()
                DebugLog.log("fast engine supported languages fetched: \(codes.count) (attempt \(attempt))")
                if codes.isEmpty, attempt < 5 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self.fetchFastSupportedCodes(attempt: attempt + 1)
                } else if !codes.isEmpty {
                    self.fastSupportedCodes = codes
                    self.prewarmFastEngineIfNeeded()
                }
            }
        }
    }

    /// True when the fast (streaming) Apple engine can serve `code` on this OS. False falls
    /// the session back to classic SFSpeechRecognizer — that covers Russian and "Auto" (not
    /// supported by Apple's new API yet) and macOS < 26.
    private func fastUsable(_ code: String) -> Bool {
        guard settings.engine == .fastApple else { return false }
        guard #available(macOS 26.0, *) else { return false }
        let codes = fastSupportedCodes.isEmpty ? Self.fastBaselineCodes : fastSupportedCodes
        return codes.contains(code.lowercased())
    }

    /// Whether THIS session (its own language — the second-language key may override the
    /// global pick) runs on the fast engine.
    private var fastSessionUsable: Bool { fastUsable(sessionLanguage) }

    /// Keep warm analyzers for the selected language — and the second language, whose
    /// trigger must answer just as fast — whenever the fast engine is active. Safe to call
    /// anytime; no-ops when the engine/language/OS doesn't qualify.
    private func prewarmFastEngineIfNeeded(engineOverride: TranscriptionEngine? = nil) {
        guard (engineOverride ?? settings.engine) == .fastApple else { return }
        if #available(macOS 26.0, *) {
            // Auto means the dual race — prewarm both of its sides; otherwise the picked
            // language plus the second-language trigger's.
            var codes: [String]
            if selectedLanguage == DictationLanguage.autoCode {
                let (primary, other) = autoRacePair()
                codes = [primary, other ?? ""]
            } else {
                codes = [
                    DictationLanguage.resolved(selectedLanguage),
                    DictationLanguage.resolved(settings.secondLanguage),
                ]
            }
            codes = codes.filter { !$0.isEmpty }
            let supported = fastSupportedCodes.isEmpty ? Self.fastBaselineCodes : fastSupportedCodes
            let service = fastSpeech
            Task {
                for code in codes where supported.contains(code.lowercased()) {
                    await service.prewarm(languageCode: code)
                }
            }
        }
    }

    /// Start the dual-language race: ONE microphone capture (the fast engine's tap) fans out
    /// to both recognizers — converted buffers stream into SpeechAnalyzer, raw buffers into a
    /// feed-mode SFSpeechRecognizer session. Both transcribe while the user speaks; the
    /// winner is picked at stop by confidence + word count, costing no extra latency.
    private func startDualSession() throws {
        guard #available(macOS 26.0, *), let plan = dualPlan else { return }

        // Live-draft partials follow the system language's side — the one the user most
        // likely speaks — so the island's Compact text isn't gibberish half the time.
        let showLegacyPartials = plan.legacy == DictationLanguage.resolvedSystemCode()

        // Both sides' partials feed the early-kill comparison and the confident-finish gate;
        // the live text follows one side, and hops to the survivor if the driver is killed.
        let legacyPartialHandler: (String) -> Void = { [weak self] text in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.dualLegacyPartial = text
                let drives = self.dualKilled == .fast || (self.dualKilled == nil && showLegacyPartials)
                if drives, self.isRecording {
                    self.recordingPanel?.state.liveText = text
                }
            }
        }
        let fastUpdateHandler: @Sendable (String) -> Void = { [weak self] text in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.dualFastPartial = text
                let drives = self.dualKilled == .legacy || (self.dualKilled == nil && !showLegacyPartials)
                if drives, self.isRecording {
                    self.recordingPanel?.state.liveText = text
                }
            }
        }

        try speechTranscriber.startLiveSessionFeed(
            onPartial: legacyPartialHandler,
            onFailure: { message in
                // The legacy side dying mid-race is not fatal — the fast side continues and
                // wins by default at stop.
                DebugLog.log("dual race: legacy side failed: \(message)")
            }
        )

        let code = plan.fast
        let service = fastSpeech
        let transcriber = speechTranscriber
        fastStartTask = Task { [weak self] in
            do {
                let generation = try await service.start(
                    languageCode: code,
                    onLevel: { [weak self] level in
                        self?.handleAudioLevel(level)
                    },
                    onUpdate: fastUpdateHandler,
                    onRawBuffer: { buffer in
                        transcriber.appendLiveBuffer(buffer)
                    },
                    onFailure: { [weak self] message in
                        DispatchQueue.main.async { self?.failFastSession(message) }
                    }
                )
                DispatchQueue.main.async { self?.dualFastGeneration = generation }
            } catch {
                DispatchQueue.main.async { self?.failFastSession(error.localizedDescription) }
            }
        }

        scheduleDualKill()
    }

    /// Live-draft feed for the dual race (any thread).
    private func pushDualLiveText(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRecording else { return }
            self.recordingPanel?.state.liveText = text
        }
    }

    /// The race's verdict: does the legacy (SFSpeechRecognizer) side win?
    ///
    /// Both recognizers report per-word confidence, and a recognizer fed the wrong language
    /// scores DRAMATICALLY lower (measured on this machine with the new API: right language
    /// ≈ 0.91–0.97, wrong language ≈ 0.04–0.28 — its "transcript" was literally commas).
    /// So the primary rule is a straight comparison; heuristics only break near-ties.
    private static func dualLegacyWins(
        fastText: String, fastConfidence: Double?,
        legacyText: String, legacyConfidence: Double
    ) -> Bool {
        func words(_ s: String) -> Int {
            s.split(whereSeparator: { $0.isWhitespace }).count
        }
        /// Punctuation-only "transcripts" (the wrong-language failure mode) count as empty.
        func meaningful(_ s: String) -> Bool {
            meaningfulCount(s) > 0
        }
        let fast = fastText.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacy = legacyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !meaningful(legacy) { return false }
        if !meaningful(fast) { return true }

        if let fastConfidence, abs(fastConfidence - legacyConfidence) > 0.08 {
            return legacyConfidence > fastConfidence
        }
        // Near-tie or no fast confidence: fall back to absolute thresholds + word count.
        if legacyConfidence >= 0.55 { return true }
        if legacyConfidence <= 0.30 { return false }
        let lw = words(legacy), fw = words(fast)
        if lw != fw { return lw > fw }
        return legacyConfidence >= 0.45
    }

    /// Kick off a streaming fast-engine session. Setup is async (actor hop + analyzer attach,
    /// normally a few ms thanks to prewarming); a failure after this point tears the recording
    /// UI down from inside the task.
    private func startFastSession() {
        guard #available(macOS 26.0, *) else { return }
        let code = sessionLanguage
        let service = fastSpeech
        fastStartTask = Task { [weak self] in
            do {
                try await service.start(
                    languageCode: code,
                    onLevel: { [weak self] level in
                        self?.handleAudioLevel(level)
                    },
                    onUpdate: { [weak self] text in
                        DispatchQueue.main.async {
                            guard let self, self.isRecording else { return }
                            self.recordingPanel?.state.liveText = text
                        }
                    },
                    onFailure: { [weak self] message in
                        DispatchQueue.main.async { self?.failFastSession(message) }
                    }
                )
            } catch {
                DispatchQueue.main.async { self?.failFastSession(error.localizedDescription) }
            }
        }
    }

    /// Tear down a legacy live session that died while recording. Main thread only.
    private func failLegacyLiveSession(_ message: String) {
        guard usingLegacyLiveSession, isRecording else { return }
        usingLegacyLiveSession = false
        isRecording = false
        recordingStartTime = nil
        speechTranscriber.cancelLiveSession()
        playErrorCue()
        hideOverlay()
        showTransientStatus(message, duration: 4.0)
    }

    /// Tear down a fast session that died while recording (mic failure, analyzer error).
    /// Also ends a dual race — its microphone lives in the fast session's tap.
    /// Must be called on the main thread.
    private func failFastSession(_ message: String) {
        DebugLog.log("fast session failed: \(message)")
        guard usingFastSession || usingDualSession, isRecording else { return }
        if usingDualSession {
            speechTranscriber.cancelLiveSession()
            usingDualSession = false
            dualPlan = nil
            resetDualKillState()
        }
        usingFastSession = false
        isRecording = false
        recordingStartTime = nil
        if #available(macOS 26.0, *) {
            let service = fastSpeech
            Task { await service.cancel() }
        }
        playErrorCue()
        hideOverlay()
        showTransientStatus(message, duration: 4.0)
    }

    /// The language the classic speech recognizer is currently configured for; lets a
    /// second-language session reconfigure only when it actually differs.
    private var speechConfiguredLanguage: String?
    /// Last system language this process acted on — the locale-change observer's no-op guard.
    private var lastSystemLanguageCode = DictationLanguage.resolvedSystemCode()

    /// The two languages the Auto race runs: the user's first preferred language, paired
    /// with the explicit second language when set, else the next distinct preferred
    /// language (a bilingual Mac lists both — ["en-RU", "ru-RU"] races en vs ru out of
    /// the box), else English. nil `other` = nothing to race against.
    private func autoRacePair() -> (primary: String, other: String?) {
        let preferred = DictationLanguage.preferredCodes()
        let primary = preferred.first ?? "en-US"
        var other: String?
        if !settings.secondLanguage.isEmpty {
            let second = DictationLanguage.resolved(settings.secondLanguage)
            if second != primary { other = second }
        }
        // The explicit second language can collapse into the primary after a system-language
        // switch (second = Русский, system becomes Russian) — fall through to the preferred
        // list so Auto keeps racing instead of silently going single-language.
        if other == nil {
            other = preferred.dropFirst().first(where: { $0 != primary })
            if other == nil && primary != "en-US" { other = "en-US" }
        }
        if other == primary { other = nil }
        return (primary, other)
    }

    /// The dual-language race this session runs, or nil for a single-language session.
    /// Auto + Apple Live: the fast side is whichever language SpeechAnalyzer supports,
    /// the legacy side (SFSpeechRecognizer) takes the other; the winner is picked at stop.
    private var dualPlan: (fast: String, legacy: String)?
    private var usingDualSession = false

    // MARK: Dual-race early kill (battery)
    // Running two recognizers heats the machine on long dictations, so after a few seconds
    // the partials are compared and the clearly-losing side is shut down — the rest of the
    // dictation runs single-engine. An ambiguous race keeps both until stop.
    private static let dualKillDelay: TimeInterval = 3.0
    private var dualKillTimer: Timer?
    private var dualFastPartial = ""
    private var dualLegacyPartial = ""
    /// Which side was killed early (nil = both alive until stop).
    private enum DualSide { case fast, legacy }
    private var dualKilled: DualSide?
    /// Generation token of the dual race's fast session — names exactly which session the
    /// early kill may abandon (a stale kill Task must not touch a newer session).
    private var dualFastGeneration: Int?

    /// One reset for the whole dual-kill state family — called from every session exit so
    /// no path can forget half of it. Returns the killed side for the stop path's join.
    @discardableResult
    private func resetDualKillState() -> DualSide? {
        dualKillTimer?.invalidate()
        dualKillTimer = nil
        let killed = dualKilled
        dualKilled = nil
        dualFastGeneration = nil
        dualFastPartial = ""
        dualLegacyPartial = ""
        return killed
    }

    /// Letters+digits only — the wrong-language side's "transcript" is often punctuation.
    private static func meaningfulCount(_ s: String) -> Int {
        s.unicodeScalars.lazy.filter { CharacterSet.alphanumerics.contains($0) }.count
    }

    private func scheduleDualKill() {
        resetDualKillState()
        dualKillTimer = Timer.scheduledTimer(withTimeInterval: Self.dualKillDelay, repeats: false) { [weak self] _ in
            self?.evaluateDualKill()
        }
    }

    private func evaluateDualKill() {
        guard usingDualSession, isRecording, dualKilled == nil, let plan = dualPlan else { return }
        let fastCount = Self.meaningfulCount(dualFastPartial)
        let legacyCount = Self.meaningfulCount(dualLegacyPartial)
        // Kill only on a clear margin — AND only a side that has actually produced output.
        // A completely silent side may just be slow to attach (cold model, recognizer
        // settling after a language switch); killing it would hand the whole dictation to
        // the wrong-language side with no stop-time recovery. Silence keeps both running —
        // worst case is the pre-optimization behavior.
        if legacyCount >= 12 && fastCount >= 1 && legacyCount >= 2 * fastCount {
            guard let generation = dualFastGeneration else {
                // The fast session hasn't handed us its token yet — a kill now would only
                // flip bookkeeping while the analyzer kept running. Let the race continue.
                DebugLog.log("dual race: skip fast kill — session not attached yet")
                return
            }
            dualKilled = .fast
            if #available(macOS 26.0, *) {
                let service = fastSpeech
                Task { await service.abandonAnalysis(generation: generation) }
            }
            DebugLog.log("dual race: early kill fast(\(plan.fast)) at \(Self.dualKillDelay)s — letters fast=\(fastCount) legacy=\(legacyCount)")
        } else if fastCount >= 12 && legacyCount >= 1 && fastCount >= 2 * legacyCount {
            dualKilled = .legacy
            speechTranscriber.cancelLiveSession()
            DebugLog.log("dual race: early kill legacy(\(plan.legacy)) at \(Self.dualKillDelay)s — letters fast=\(fastCount) legacy=\(legacyCount)")
        } else {
            DebugLog.log("dual race: no early kill — letters fast=\(fastCount) legacy=\(legacyCount), both continue")
        }
    }

    private func startRecording(language: String? = nil, translate: Bool = false) {
        guard !isRecording && !isTranscribing else { return }

        let requested = language ?? selectedLanguage
        sessionLanguage = DictationLanguage.resolved(requested)
        sessionTranslate = translate
        if language == nil { activeTrigger = activeTrigger ?? .primary }

        // Auto + Apple Live = the dual-language race. Selecting anything but Auto switches
        // it off. The pair comes from `autoRacePair()` — the user's own bilingual setup.
        dualPlan = nil
        if requested == DictationLanguage.autoCode && settings.engine == .fastApple && !translate {
            let (primary, maybeOther) = autoRacePair()
            if let other = maybeOther {
                if fastUsable(primary) {
                    dualPlan = (fast: primary, legacy: other)
                } else if fastUsable(other) {
                    dualPlan = (fast: other, legacy: primary)
                }
            }
            // Provisional until the winner is known; with no race possible, dictate in the
            // primary preferred language through whichever path serves it.
            sessionLanguage = dualPlan?.fast ?? primary
        }

        // Check engine readiness
        switch settings.engine {
        case .apple, .fastApple:
            // The fast engine needs no readiness check (it prepares itself), but the classic
            // recognizer must be ready whenever it participates: the .apple engine itself,
            // the fallback for languages SpeechAnalyzer can't do, or the dual race's legacy side.
            let legacyLanguage: String?
            if settings.engine == .apple {
                legacyLanguage = sessionLanguage
            } else if let plan = dualPlan {
                legacyLanguage = plan.legacy
            } else if !fastSessionUsable {
                legacyLanguage = sessionLanguage
            } else {
                legacyLanguage = nil
            }
            if let lang = legacyLanguage {
                if !speechTranscriber.isReady || speechConfiguredLanguage != lang {
                    speechTranscriber.configure(language: lang)
                    speechConfiguredLanguage = lang
                    guard speechTranscriber.isReady else {
                        print("mywisper: Speech recognizer not available")
                        showTransientStatus("Speech recognizer not available")
                        return
                    }
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

        usingLiveSession = shouldUseLiveSession
        usingDualSession = dualPlan != nil
        usingFastSession = !usingDualSession && fastSessionUsable
        // Apple Live with a language the new API can't do (Russian, Auto) or macOS < 26:
        // stream into the classic recognizer instead, so stopping is still near-instant.
        usingLegacyLiveSession = !usingDualSession && !usingFastSession
            && settings.engine == .fastApple && speechTranscriber.isReady
        do {
            if usingDualSession {
                try startDualSession()
            } else if usingFastSession {
                // Async setup; failures surface via failFastSession from inside the task.
                startFastSession()
            } else if usingLegacyLiveSession {
                try speechTranscriber.startLiveSession(
                    onLevel: { [weak self] level in
                        self?.handleAudioLevel(level)
                    },
                    onPartial: { [weak self] text in
                        DispatchQueue.main.async {
                            guard let self, self.isRecording else { return }
                            self.recordingPanel?.state.liveText = text
                        }
                    },
                    onFailure: { [weak self] message in
                        DispatchQueue.main.async { self?.failLegacyLiveSession(message) }
                    }
                )
            } else if usingLiveSession {
                try liveController.start(
                    language: sessionLanguage,
                    modelPath: settings.whisperModelPath,
                    segmentSeconds: settings.liveSegmentSeconds
                )
            } else {
                try audioRecorder.startRecording()
            }
        } catch {
            print("mywisper: Failed to start recording: \(error.localizedDescription)")
            usingLiveSession = false
            usingFastSession = false
            usingLegacyLiveSession = false
            usingDualSession = false
            dualPlan = nil
            resetDualKillState()
            playErrorCue()
            showTransientStatus("Failed to start recording — check microphone permission")
            return
        }

        // Whisper transcribes in the session's language (restored on delivery).
        if settings.engine == .whisper && sessionLanguage != selectedLanguage {
            whisperTranscriber.setLanguage(sessionLanguage)
        }

        isRecording = true
        isCancelled = false
        maxAudioLevel = 0
        recordingStartTime = Date()
        hotkeyManager.isOperationActive = true
        activity.hold()

        // Session routing trace: which language/path this press actually got.
        DebugLog.log("session start: lang=\(sessionLanguage) dual=\(dualPlan.map { "\($0.fast)|\($0.legacy)" } ?? "-") fast=\(usingFastSession) legacyLive=\(usingLegacyLiveSession) whisperLive=\(usingLiveSession) engine=\(settings.engine.rawValue) translate=\(sessionTranslate) supportedCodes=\(fastSupportedCodes.count)")

        // Light audible cue so it's clear recording actually started.
        playCue()

        // Name the mode when it isn't the plain default, so a held right ⌥/⌘ visibly
        // landed: the overlay says which language (or translation) this session is.
        let status: String
        if let plan = dualPlan {
            let a = plan.fast.prefix(2).uppercased()
            let b = plan.legacy.prefix(2).uppercased()
            status = "Recording (Auto \(a)/\(b))..."
        } else if sessionTranslate {
            status = "Recording (→ \(settings.translationTargetLanguage.uppercased()))..."
        } else if sessionLanguage != DictationLanguage.resolved(selectedLanguage) {
            status = "Recording (\(DictationLanguage.displayName(for: sessionLanguage)))..."
        } else {
            status = "Recording..."
        }
        showOverlay(status: status)
        recordingPanel?.state.isRecording = true
        recordingPanel?.state.isTranscribing = false
        recordingPanel?.state.isLiveSession = usingLiveSession
        recordingPanel?.state.liveSegmentsDone = 0
        recordingPanel?.state.elapsedSeconds = 0
        // Reset the voice visuals to a live-and-silent baseline and fire the one-shot
        // session effects (glow bloom, ripple, sweep phase).
        recordingPanel?.state.audioLevel = 0
        recordingPanel?.state.levelHistory = [Float](repeating: 0, count: OverlayState.levelHistoryCount)
        recordingPanel?.state.isAudioAlive = true
        recordingPanel?.state.liveText = ""
        recordingPanel?.state.sessionEpoch += 1
        lastLevelAt = Date()
        startMicWatchdog()
    }

    private func stopRecordingAndTranscribe() {
        guard isRecording else { return }

        // Silent-mic guard: if nothing rose above near-silence for the whole recording, the audio
        // is effectively empty. Whisper (and cloud Whisper) hallucinate stock phrases on silence,
        // so skip transcription entirely and tell the user instead of pasting garbage. Only trips
        // on a genuinely dead mic (wrong input device, muted, unplugged) — the threshold is far
        // below real speech.
        if maxAudioLevel < silenceLevelThreshold {
            if usingDualSession {
                if #available(macOS 26.0, *) {
                    let service = fastSpeech
                    Task { await service.cancel() }
                }
                speechTranscriber.cancelLiveSession()
                usingDualSession = false
                dualPlan = nil
                resetDualKillState()
            } else if usingFastSession {
                if #available(macOS 26.0, *) {
                    let service = fastSpeech
                    Task { await service.cancel() }
                }
                usingFastSession = false
            } else if usingLegacyLiveSession {
                speechTranscriber.cancelLiveSession()
                usingLegacyLiveSession = false
            } else if usingLiveSession {
                liveController.cancel()
                usingLiveSession = false
            } else {
                _ = audioRecorder.stopRecordingAndGetURL()
            }
            isRecording = false
            isTranscribing = false
            recordingPanel?.state.progress = nil
            hideOverlay()
            print("mywisper: Recording was silent (peak level \(maxAudioLevel)) — skipping transcription")
            showTransientStatus("No speech detected — check your microphone")
            return
        }

        // Dual-language race: both sides transcribed WHILE the user spoke. Finalize them in
        // parallel, pick the winner (confidence + word count), and hand its text — under its
        // language — to the shared pipeline. The pick itself costs nothing.
        if usingDualSession, let plan = dualPlan {
            usingDualSession = false
            dualPlan = nil
            isRecording = false
            // Snapshot the live drafts BEFORE the state reset wipes them — the confident
            // early-deliver gate compares against them; reading the cleared vars made the
            // gate always pass (first finisher won unconditionally).
            let finalFastPartial = dualFastPartial
            let finalLegacyPartial = dualLegacyPartial
            let killedSide = resetDualKillState()

            let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
            if duration < AudioRecorder.minimumDuration {
                if #available(macOS 26.0, *) {
                    let service = fastSpeech
                    Task { await service.cancel() }
                }
                speechTranscriber.cancelLiveSession()
                isTranscribing = false
                recordingPanel?.state.progress = nil
                hideOverlay()
                print("mywisper: Recording too short")
                showTransientStatus("Recording too short")
                return
            }

            isTranscribing = true
            recordingPanel?.state.statusText = "Transcribing..."
            recordingPanel?.state.isRecording = false
            recordingPanel?.state.isTranscribing = true
            recordingPanel?.state.progress = nil

            let completionHandler = makeTranscriptionCompletionHandler()

            // Join point for the two finalizations (both call back on main).
            final class DualJoin {
                var fastText: String?
                var fastConfidence: Double?
                var fastError: Error?
                var fastDone = false
                var legacy: (text: String, confidence: Double)?
                var legacyDone = false
                /// Set once the text is handed to the pipeline — the slower side's result
                /// is then discarded, so a confident first finisher isn't held hostage.
                var delivered = false
            }
            let join = DualJoin()

            /// A side finished with decisive confidence (right language ≈0.76–0.97 vs wrong
            /// ≈0.02–0.47 measured) — deliver NOW instead of waiting for the loser to
            /// finalize. This is what makes Auto as fast as a single engine.
            let earlyDeliverThreshold = 0.75
            // Deliver early ONLY when confident AND the other side's live draft is clearly
            // behind — on phonetically close pairs a wrong-language recognizer can be fluent,
            // and first-finisher-wins must not beat the stop-time comparison there.
            let earlyDeliver: (String, String, Double, String) -> Void = { [weak self] text, language, confidence, otherPartial in
                guard let self, !join.delivered else { return }
                let own = Self.meaningfulCount(text)
                let other = Self.meaningfulCount(otherPartial)
                guard own >= 2 * max(other, 1) || other == 0 else { return }
                join.delivered = true
                self.sessionLanguage = language
                DebugLog.log("dual race: confident early deliver \(language) conf=\(String(format: "%.2f", confidence)) — not waiting for the other side")
                completionHandler(.success(text))
            }

            let resolve: () -> Void = { [weak self] in
                guard let self, !join.delivered, join.fastDone, join.legacyDone else { return }
                let fastText = join.fastText ?? ""
                let legacyText = join.legacy?.text ?? ""
                let confidence = join.legacy?.confidence ?? 0
                if fastText.isEmpty && legacyText.isEmpty {
                    if let error = join.fastError {
                        completionHandler(.failure(error))
                    } else if killedSide != nil {
                        // One side was killed early and the SURVIVOR came back empty (it
                        // died mid-dictation) — that's a failure to surface, not silence.
                        completionHandler(.failure(NSError(
                            domain: "mywisper", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Transcription failed — please try again"]
                        )))
                    } else {
                        completionHandler(.success(""))
                    }
                    return
                }
                let legacyWins = Self.dualLegacyWins(
                    fastText: fastText, fastConfidence: join.fastConfidence,
                    legacyText: legacyText, legacyConfidence: confidence
                )
                join.delivered = true
                self.sessionLanguage = legacyWins ? plan.legacy : plan.fast
                // The tuning trace for the race thresholds.
                DebugLog.log("dual race: fast(\(plan.fast)) conf=\(join.fastConfidence.map { String(format: "%.2f", $0) } ?? "-") words=\(fastText.split(separator: " ").count) '\(fastText.prefix(48))' | legacy(\(plan.legacy)) conf=\(String(format: "%.2f", confidence)) words=\(legacyText.split(separator: " ").count) '\(legacyText.prefix(48))' -> winner \(self.sessionLanguage)")
                completionHandler(.success(legacyWins ? legacyText : fastText))
            }

            func meaningful(_ s: String) -> Bool {
                Self.meaningfulCount(s) > 0
            }

            if killedSide == .legacy {
                // Killed early — its session is already cancelled; it lost by definition.
                join.legacy = (text: "", confidence: 0)
                join.legacyDone = true
            } else {
                speechTranscriber.finishLiveSession { [weak self] result in
                    DispatchQueue.main.async {
                        let text = (try? result.get()) ?? ""
                        let confidence = self?.speechTranscriber.lastLiveAverageConfidence ?? 0
                        join.legacy = (text: text, confidence: confidence)
                        join.legacyDone = true
                        if confidence >= earlyDeliverThreshold, meaningful(text) {
                            earlyDeliver(text, plan.legacy, confidence, finalFastPartial)
                        }
                        resolve()
                    }
                }
            }
            if #available(macOS 26.0, *) {
                let startTask = fastStartTask
                let service = fastSpeech
                Task {
                    await startTask?.value
                    do {
                        let result = try await service.finish()
                        DispatchQueue.main.async {
                            join.fastText = result.text
                            join.fastConfidence = result.confidence
                            join.fastDone = true
                            if let confidence = result.confidence,
                               confidence >= earlyDeliverThreshold, meaningful(result.text) {
                                earlyDeliver(result.text, plan.fast, confidence, finalLegacyPartial)
                            }
                            resolve()
                        }
                    } catch {
                        DispatchQueue.main.async {
                            join.fastError = error
                            join.fastDone = true
                            resolve()
                        }
                    }
                }
            }
            return
        }

        // Fast (streaming) Apple path: the audio was transcribed WHILE the user spoke, so
        // finalization is near-instant — stop the mic, finalize the tail, hand the text to the
        // shared pipeline.
        if usingFastSession {
            usingFastSession = false
            isRecording = false

            let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
            if duration < AudioRecorder.minimumDuration {
                if #available(macOS 26.0, *) {
                    let service = fastSpeech
                    Task { await service.cancel() }
                }
                isTranscribing = false
                recordingPanel?.state.progress = nil
                hideOverlay()
                print("mywisper: Recording too short")
                showTransientStatus("Recording too short")
                return
            }

            isTranscribing = true
            recordingPanel?.state.statusText = "Transcribing..."
            recordingPanel?.state.isRecording = false
            recordingPanel?.state.isTranscribing = true
            recordingPanel?.state.progress = nil

            let completionHandler = makeTranscriptionCompletionHandler()
            if #available(macOS 26.0, *) {
                let startTask = fastStartTask
                let service = fastSpeech
                Task {
                    // A very quick tap can stop before start finished attaching; wait it out.
                    await startTask?.value
                    do {
                        let result = try await service.finish()
                        completionHandler(.success(result.text))
                    } catch {
                        completionHandler(.failure(error))
                    }
                }
            }
            return
        }

        // Legacy live path (Apple Live's fallback, e.g. Russian): SFSpeechRecognizer already
        // processed the audio while the user spoke — finalization lands in a fraction of a second.
        if usingLegacyLiveSession {
            usingLegacyLiveSession = false
            isRecording = false

            let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
            if duration < AudioRecorder.minimumDuration {
                speechTranscriber.cancelLiveSession()
                isTranscribing = false
                recordingPanel?.state.progress = nil
                hideOverlay()
                print("mywisper: Recording too short")
                showTransientStatus("Recording too short")
                return
            }

            isTranscribing = true
            recordingPanel?.state.statusText = "Transcribing..."
            recordingPanel?.state.isRecording = false
            recordingPanel?.state.isTranscribing = true
            recordingPanel?.state.progress = nil

            speechTranscriber.finishLiveSession(completion: makeTranscriptionCompletionHandler())
            return
        }

        // Live (segmented) Whisper path: most segments were already transcribed while recording.
        // Stop the recorder, then deliver the combined transcript once the tail finishes.
        if usingLiveSession {
            isRecording = false
            isTranscribing = true
            recordingPanel?.state.statusText = "Transcribing..."
            recordingPanel?.state.isRecording = false
            recordingPanel?.state.isTranscribing = true
            // Segment-level progress isn't meaningful to the user; show the indeterminate spinner.
            recordingPanel?.state.progress = nil

            let completionHandler = makeTranscriptionCompletionHandler()
            liveController.finish { [weak self] result in
                guard let self = self, !self.isCancelled else { return }
                // An empty result combined with the too-short flag means an accidental tap —
                // mirror the classic path instead of running the full paste pipeline on "".
                if case .success(let text) = result, text.isEmpty, self.liveController.lastRecordingWasTooShort {
                    self.isTranscribing = false
                    self.hideOverlay()
                    print("mywisper: Recording too short")
                    self.showTransientStatus("Recording too short")
                    return
                }
                completionHandler(result)
            }
            return
        }

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
                playErrorCue()
                showTransientStatus("Recording failed")
            }
            return
        }

        let completionHandler = makeTranscriptionCompletionHandler()

        switch settings.engine {
        case .apple, .fastApple:
            // .fastApple only reaches this file-based path as the classic fallback (unsupported
            // language or macOS < 26) — the streaming path returned earlier.
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
                language: sessionLanguage,
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

                // A second-language session borrowed the Whisper engine's language; hand it back.
                if self.settings.engine == .whisper && self.sessionLanguage != self.selectedLanguage {
                    self.whisperTranscriber.setLanguage(self.selectedLanguage)
                }

                // If the operation was cancelled, discard the result
                guard !self.isCancelled else {
                    self.activity.release()
                    return
                }

                switch result {
                case .success(let transcribedText):
                    // Drop known Whisper hallucinations (YouTube-style "Субтитры делал…", "Amara.org",
                    // etc.) that surface on near-silent/low-SNR audio — treat them as no speech so the
                    // empty-result path below shows a notice instead of pasting the bogus phrase.
                    let rawText = self.isLikelyHallucination(transcribedText) ? "" : transcribedText
                    if self.sessionTranslate && !rawText.isEmpty {
                        self.translateThenDeliver(rawText)
                    } else {
                        self.deliverTranscription(rawText)
                    }
                case .failure(let error):
                    print("mywisper: Error: \(error)")
                    self.isTranscribing = false
                    self.hideOverlay()
                    self.activity.release()
                    self.surfaceTranscriptionError(error)
                }
            }
        }
    }

    /// Translate the transcript before delivery (the right-⌘ session). On any failure the
    /// user's words are NOT lost: the original goes to the clipboard and nothing is pasted.
    private func translateThenDeliver(_ rawText: String) {
        guard #available(macOS 26.0, *) else {
            finishWithTranslationFailure(rawText, message: "Translation needs macOS 26 or newer")
            return
        }
        let source = String(sessionLanguage.prefix(2)).lowercased()
        guard sessionLanguage != DictationLanguage.autoCode else {
            finishWithTranslationFailure(rawText, message: "Translation needs a specific language (not Auto)")
            return
        }
        recordingPanel?.state.statusText = "Translating..."
        recordingPanel?.state.isTranscribing = true
        recordingPanel?.state.progress = nil

        let pair = TranslationEngine.Pair(source: source, target: settings.translationTargetLanguage)
        Task { [weak self] in
            do {
                let translated = try await TranslationEngine.shared.translate(rawText, pair: pair)
                DispatchQueue.main.async {
                    guard let self = self, !self.isCancelled else { return }
                    self.deliverTranscription(translated, originalBeforeTranslation: rawText)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self = self, !self.isCancelled else { return }
                    self.finishWithTranslationFailure(
                        rawText,
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    /// Translation failed: keep the words (clipboard), paste nothing, say why.
    private func finishWithTranslationFailure(_ original: String, message: String) {
        isTranscribing = false
        hideOverlay()
        activity.release()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(original, forType: .string)
        playErrorCue()
        showTransientStatus("Translation failed — original copied to clipboard (\(message))", duration: 5.0)
    }

    /// Shared delivery tail: AI post-processing, dictionary, history, paste, teardown.
    /// `originalBeforeTranslation` preserves the pre-translation dictation for history.
    private func deliverTranscription(_ rawText: String, originalBeforeTranslation: String? = nil) {
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
                                    rawText: originalBeforeTranslation ?? rawText,
                                    engine: self.settings.engine.rawValue,
                                    language: self.sessionLanguage,
                                    durationSeconds: recordingDuration,
                                    aiProcessed: true,
                                    aiModel: self.settings.openAIModel
                                )
                                self.history.add(record)
                                self.pasteAndNotify(finalText)
                                self.activity.release()
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
                                rawText: originalBeforeTranslation ?? (processedText != rawText ? rawText : nil),
                                engine: self.settings.engine.rawValue,
                                language: self.sessionLanguage,
                                durationSeconds: recordingDuration
                            )
                            self.history.add(record)
                            self.pasteAndNotify(processedText)
                        } else {
                            // Empty result (e.g. silence) — tell the user instead of doing nothing.
                            self.showTransientStatus("No speech detected")
                        }
                        self.activity.release()
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
        // A retry replays the pending recording's own session parameters, not whatever
        // the last live session happened to be.
        sessionLanguage = pending.language
        sessionTranslate = false
        activity.hold()
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

        // The recording panel only attracts the eye when it's actually showing recording/
        // transcribing state. For standalone notices (errors, "No speech detected") it is not
        // visible here, so also surface the message in the always-on-top toast HUD — this is the
        // only feedback the user sees when a mywisper window is focused.
        StatusHUD.shared.show(message, systemImage: nil, duration: max(duration, 1.3))

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
        // Soft cue that the transcription finished and the text was delivered.
        playCue()
        let result = textPaster.paste(text: text, previousApp: previousApp)
        if result == .copiedToClipboardOnly {
            showTransientStatus("Copied to clipboard — press ⌘V (grant Accessibility to auto-paste)", duration: 4.0)
        }
    }

    /// Play the chosen sound cue (start of recording and completion). Gated by the
    /// `playStartSound` setting; the sound is `settings.selectedSoundName`.
    private func playCue() {
        guard settings.playStartSound else { return }
        SoundLibrary.play(named: settings.selectedSoundName)
    }

    /// Play the dedicated error sound when something genuinely fails (transcription
    /// error, dropped connection, recording failure). Gated by the same `playStartSound`
    /// master switch so turning sounds off silences this too.
    private func playErrorCue() {
        guard settings.playStartSound else { return }
        SoundLibrary.playError()
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
        // Genuine failure (transcription crashed, network/connection error, etc.) — play
        // the dedicated error sound and surface the message.
        playErrorCue()
        showTransientStatus(error.localizedDescription, duration: 4.0)
    }

    /// Conservative detector for Whisper's stock hallucinations on near-silent / low-SNR audio.
    /// Kept deliberately narrow so it never eats real dictation: it only fires on subtitle-credit
    /// signatures that essentially never occur in speech, or on degenerate single-token repetition.
    /// (Phrases like "продолжение следует" are intentionally NOT listed — they can be real.)
    private func isLikelyHallucination(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        // Subtitle/credit signatures — if any appears, the whole result is bogus.
        let signatures = [
            "dimatorzok", "amara.org",
            "субтитры делал", "субтитры создавал", "субтитры подготовил",
            "субтитры предоставлены", "редактор субтитров", "субтитры добавил",
        ]
        if signatures.contains(where: { normalized.contains($0) }) { return true }

        // Degenerate repetition of a single short token (e.g. "you you you", "так так так так").
        let words = normalized
            .components(separatedBy: CharacterSet(charactersIn: " .,!?-—…\n\t\""))
            .filter { !$0.isEmpty }
        if words.count >= 3, Set(words).count == 1 { return true }

        return false
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
        // Every session-terminal path funnels through here (delivery, cancel, errors,
        // silence, too-short) and it never runs mid-session — the safe single place to
        // let macOS nap the process again.
        activity.release()
    }

    /// Prewarm the Apple Translation session for the configured pair so the first
    /// right-⌘ dictation translates warm (~300 ms) instead of cold (~1 s).
    private func prewarmTranslationIfNeeded(target: String? = nil) {
        let targetCode = target ?? settings.translationTargetLanguage
        guard !targetCode.isEmpty else { return }
        if #available(macOS 26.0, *) {
            let source = String(DictationLanguage.resolved(selectedLanguage).prefix(2)).lowercased()
            guard source != "au" else { return }  // "auto" has no concrete source language
            let pair = TranslationEngine.Pair(source: source, target: targetCode)
            Task {
                await TranslationEngine.shared.retainOnly(pair)
                await TranslationEngine.shared.prewarm(pair)
            }
        }
    }

    private func applyHotkeySettings() {
        hotkeyManager.useCustomHotkey = settings.useCustomHotkey
        hotkeyManager.secondaryTriggerEnabled = !settings.secondLanguage.isEmpty
        hotkeyManager.translateTriggerEnabled = settings.translationActive
        hotkeyManager.customHotkeyKeyCode = settings.customHotkeyKeyCode
        hotkeyManager.customHotkeyModifiers = settings.customHotkeyModifiers
        hotkeyManager.doubleTapInterval = settings.hotkeyDoubleTapInterval
        hotkeyManager.useAIToggleHotkey = settings.useAIToggleHotkey
        hotkeyManager.aiToggleHotkeyKeyCode = settings.aiToggleHotkeyKeyCode
        hotkeyManager.aiToggleHotkeyModifiers = settings.aiToggleHotkeyModifiers
        hotkeyManager.useCycleModeHotkey = settings.useCycleModeHotkey
        hotkeyManager.cycleModeHotkeyKeyCode = settings.cycleModeHotkeyKeyCode
        hotkeyManager.cycleModeHotkeyModifiers = settings.cycleModeHotkeyModifiers
        hotkeyManager.cancelHotkeyKeyCode = settings.cancelHotkeyKeyCode
    }

    /// Toggle AI post-processing on/off and surface the new state in the toast HUD so the user
    /// gets feedback even when a mywisper window is focused. Bound to the "AI toggle" hotkey.
    /// The menu's "AI Processing: On/Off" line updates via menuNeedsUpdate.
    private func toggleAIProcessing() {
        settings.aiProcessingEnabled.toggle()
        playAIActionCue()
        if settings.aiProcessingEnabled {
            StatusHUD.shared.show("AI Processing: On", systemImage: "brain")
        } else {
            // No dedicated "brain with slash" SF Symbol exists across our deployment target;
            // pair the brain with a slash circle to read clearly as "off".
            StatusHUD.shared.show("AI Processing: Off", systemImage: "slash.circle")
        }
    }

    /// Advance to the next AI mode preset and surface the new mode name in the toast HUD.
    /// Bound to the "Cycle AI mode" hotkey. The menu's "AI Mode: …" line updates via menuNeedsUpdate.
    private func cycleAIMode() {
        guard let preset = settings.cycleToNextPreset() else {
            StatusHUD.shared.show("No AI modes available", systemImage: "exclamationmark.triangle")
            return
        }
        playAIActionCue()
        StatusHUD.shared.show("AI Mode: \(preset.name)", systemImage: "text.badge.star")
    }

    /// Fixed tap cue for AI hotkey actions (toggle / cycle mode). Gated only by
    /// `aiActionSoundEnabled`; the sound itself isn't configurable.
    private func playAIActionCue() {
        guard settings.aiActionSoundEnabled else { return }
        SoundLibrary.playActionCue()
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

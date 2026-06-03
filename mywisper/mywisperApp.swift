//
//  mywisperApp.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import SwiftUI
import AVFoundation
import Combine

@main
struct mywisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    /// Single persistent menu instance. `buildMenu()` repopulates THIS instance in place so that
    /// `menuNeedsUpdate(_:)` refreshes the exact menu AppKit is about to show (rebuilding a fresh
    /// NSMenu and reassigning statusItem.menu would only take effect on the *next* open).
    private let statusMenu = NSMenu()
    private var dictationManager: DictationManager!
    private var settingsWindow: NSWindow?
    private var homeWindow: NSWindow?
    private var transcribeFileWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up system notifications first so they're ready by the time the user
        // hits a transient cloud failure.
        NotificationManager.shared.configure()

        dictationManager = DictationManager()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "My Whisper")
        }

        buildMenu()

        dictationManager.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.buildMenu()
                self?.updateIcon()
            }
        }.store(in: &cancellables)

        // Rebuild menu when the pending list changes (e.g. failures arriving in the background).
        dictationManager.pendingStore.$items.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.buildMenu()
            }
        }.store(in: &cancellables)

        // Rebuild menu when background file-transcription state changes (status pill).
        FileTranscriptionService.shared.$menuBarStatus.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.buildMenu()
            }
        }.store(in: &cancellables)

        // Notification action "Show" → open the transcribe-file window.
        NotificationCenter.default.addObserver(
            forName: .showFileTranscriptionRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.openTranscribeFile()
        }

        // Re-open the onboarding checklist (from Settings) or open Settings (from onboarding).
        NotificationCenter.default.addObserver(
            forName: .showOnboardingRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.openOnboarding()
        }
        NotificationCenter.default.addObserver(
            forName: .openSettingsRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.openSettings()
        }

        // Apply the Dock-icon preference now, and whenever it changes. A persistent Dock icon
        // keeps mywisper reachable even when the menu-bar icon is hidden behind the notch.
        applyActivationPolicy(SettingsManager.shared.showDockIcon)
        SettingsManager.shared.$showDockIcon.sink { [weak self] show in
            DispatchQueue.main.async { self?.applyActivationPolicy(show) }
        }.store(in: &cancellables)

        // First launch: show the setup checklist.
        if !SettingsManager.shared.hasCompletedOnboarding {
            DispatchQueue.main.async { [weak self] in
                self?.openOnboarding()
            }
        }
    }

    private var cancellables = Set<AnyCancellable>()

    /// When the user re-launches mywisper from Finder/Spotlight/Dock — e.g. because the menu-bar
    /// icon is hidden behind the notch when many apps are running — open Settings (or the
    /// onboarding checklist on a fresh install) so there's always a reliable way back in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if SettingsManager.shared.hasCompletedOnboarding {
            openSettings()
        } else {
            openOnboarding()
        }
        return true
    }

    /// Show/hide the persistent Dock icon. `.regular` adds a Dock icon (and a standard app menu
    /// when focused — handy for Quit); `.accessory` is the menu-bar-only default.
    private func applyActivationPolicy(_ showDock: Bool) {
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
    }

    private func updateIcon() {
        let iconName: String
        if dictationManager.isRecording {
            iconName = "mic.fill"
        } else if dictationManager.isTranscribing {
            iconName = "ellipsis.circle"
        } else {
            iconName = "mic"
        }
        statusItem.button?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "My Whisper")
    }

    private func buildMenu() {
        // Repopulate the persistent menu in place (see `statusMenu` docs).
        let menu = statusMenu
        menu.removeAllItems()

        // Background file-transcription status (only when active)
        if let fileStatus = FileTranscriptionService.shared.menuBarStatus {
            let statusItem = NSMenuItem(title: fileStatus, action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)

            let showItem = NSMenuItem(title: "Show Transcription Window…", action: #selector(openTranscribeFile), keyEquivalent: "")
            showItem.target = self
            menu.addItem(showItem)

            menu.addItem(.separator())
        }

        // Status
        let statusText: String
        if dictationManager.isRecording {
            statusText = "● Recording..."
        } else if dictationManager.isTranscribing {
            statusText = "◌ Transcribing..."
        } else {
            statusText = "● Ready"
        }
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        // Show last transcription (truncated, click to copy)
        if !dictationManager.currentTranscription.isEmpty
            && !dictationManager.isRecording
            && !dictationManager.isTranscribing {
            let fullText = dictationManager.currentTranscription
            let transcriptionItem = NSMenuItem(title: "", action: #selector(copyLastTranscription), keyEquivalent: "c")
            transcriptionItem.target = self
            // Wrap long transcriptions across multiple lines instead of cutting them off at
            // one line; the full text stays in the tooltip and is copied on click.
            transcriptionItem.attributedTitle = Self.wrappedMenuTitle(fullText, prefix: "📋 ")
            transcriptionItem.toolTip = fullText
            menu.addItem(transcriptionItem)
        }

        menu.addItem(.separator())

        // Recording control
        let recordTitle = dictationManager.isRecording ? "Stop Recording" : "Start Recording"
        let settings = SettingsManager.shared

        let recordItem: NSMenuItem
        if settings.useCustomHotkey {
            let keyStr = HotkeyManager.keyCodeToString(settings.customHotkeyKeyCode)
            recordItem = NSMenuItem(title: recordTitle, action: #selector(toggleRecording), keyEquivalent: keyStr.lowercased())
            recordItem.keyEquivalentModifierMask = convertModifiers(settings.customHotkeyModifiers)
        } else {
            recordItem = NSMenuItem(title: recordTitle, action: #selector(toggleRecording), keyEquivalent: "r")
        }
        recordItem.target = self
        menu.addItem(recordItem)

        if settings.useDoubleTapFn {
            let fnHint = NSMenuItem(title: "Also: Double-tap Fn", action: nil, keyEquivalent: "")
            fnHint.isEnabled = false
            menu.addItem(fnHint)
        }

        // Undo last paste
        let undoItem = NSMenuItem(title: "Undo Last Paste", action: #selector(undoLastPaste), keyEquivalent: "z")
        undoItem.keyEquivalentModifierMask = [.command, .shift]
        undoItem.target = self
        undoItem.isEnabled = dictationManager.canUndoLastPaste
        menu.addItem(undoItem)

        menu.addItem(.separator())

        // Language
        let langMenu = NSMenu()
        for lang in DictationLanguage.all {
            let item = NSMenuItem(title: lang.displayName, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.code
            item.state = dictationManager.selectedLanguage == lang.code ? .on : .off
            langMenu.addItem(item)
            if lang.isAuto { langMenu.addItem(.separator()) }
        }

        let langItem = NSMenuItem(title: "Language: \(DictationLanguage.displayName(for: dictationManager.selectedLanguage))", action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        menu.addItem(langItem)

        menu.addItem(.separator())

        // Engine indicator
        let engineName: String
        switch SettingsManager.shared.engine {
        case .apple: engineName = "Apple Speech"
        case .whisper: engineName = "Whisper"
        case .cloud: engineName = "Cloud (OpenAI)"
        }
        let engineItem = NSMenuItem(title: "Engine: \(engineName)", action: nil, keyEquivalent: "")
        engineItem.isEnabled = false
        menu.addItem(engineItem)

        // AI Processing — quick toggle
        menu.addItem(.separator())

        let aiToggle: NSMenuItem
        if settings.useAIToggleHotkey {
            let aiKeyStr = HotkeyManager.keyCodeToString(settings.aiToggleHotkeyKeyCode)
            aiToggle = NSMenuItem(
                title: settings.aiProcessingEnabled ? "AI Processing: On" : "AI Processing: Off",
                action: #selector(toggleAI),
                keyEquivalent: aiKeyStr.lowercased()
            )
            aiToggle.keyEquivalentModifierMask = convertModifiers(settings.aiToggleHotkeyModifiers)
        } else {
            aiToggle = NSMenuItem(
                title: settings.aiProcessingEnabled ? "AI Processing: On" : "AI Processing: Off",
                action: #selector(toggleAI),
                keyEquivalent: "a"
            )
        }
        aiToggle.target = self
        aiToggle.state = settings.aiProcessingEnabled ? .on : .off
        menu.addItem(aiToggle)

        if SettingsManager.shared.aiProcessingEnabled && !SettingsManager.shared.openAIKey.isEmpty {
            // Quick preset submenu
            let presetMenu = NSMenu()
            for preset in SettingsManager.shared.aiPresets {
                let item = NSMenuItem(title: preset.name, action: #selector(selectPreset(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = preset.id
                item.state = SettingsManager.shared.selectedPresetId == preset.id ? .on : .off
                presetMenu.addItem(item)
            }
            let presetItem = NSMenuItem(title: "AI Mode: \(currentPresetName)", action: nil, keyEquivalent: "")
            presetItem.submenu = presetMenu
            menu.addItem(presetItem)
        }

        // Pending uploads (failed cloud transcriptions awaiting retry)
        let pendingItems = dictationManager.pendingStore.items
        if !pendingItems.isEmpty {
            menu.addItem(.separator())

            let header = NSMenuItem(title: "Pending uploads (\(pendingItems.count))", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for item in pendingItems {
                let timeAgo = formatTimeAgo(item.createdAt)
                let dur = formatDuration(item.durationSeconds)
                let title = "\(timeAgo) · \(dur)"

                let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")

                let submenu = NSMenu()
                let retry = NSMenuItem(title: "Retry", action: #selector(retryPending(_:)), keyEquivalent: "")
                retry.target = self
                retry.representedObject = item.id
                submenu.addItem(retry)

                let discard = NSMenuItem(title: "Discard", action: #selector(discardPending(_:)), keyEquivalent: "")
                discard.target = self
                discard.representedObject = item.id
                submenu.addItem(discard)

                if let err = item.lastError {
                    submenu.addItem(.separator())
                    let errItem = NSMenuItem(title: "Error: \(err)", action: nil, keyEquivalent: "")
                    errItem.isEnabled = false
                    submenu.addItem(errItem)
                }

                row.submenu = submenu
                menu.addItem(row)
            }

            menu.addItem(.separator())
        }

        // Transcribe File
        let transcribeFileItem = NSMenuItem(title: "Transcribe File...", action: #selector(openTranscribeFile), keyEquivalent: "t")
        transcribeFileItem.target = self
        menu.addItem(transcribeFileItem)

        // History
        let historyCount = TranscriptionHistory.shared.records.count
        let historyTitle = historyCount > 0 ? "History (\(historyCount))" : "History"
        let historyItem = NSMenuItem(title: historyTitle, action: #selector(openHome), keyEquivalent: "h")
        historyItem.target = self
        menu.addItem(historyItem)

        // Setup Guide (onboarding)
        let onboardingItem = NSMenuItem(title: "Setup Guide...", action: #selector(openOnboarding), keyEquivalent: "")
        onboardingItem.target = self
        menu.addItem(onboardingItem)

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Become the menu's delegate so `menuNeedsUpdate(_:)` rebuilds it right before it opens —
        // this guarantees the menu reflects current SettingsManager state (AI toggle, engine,
        // language, preset) even when those change via hotkey and no rebuild publisher fired.
        menu.delegate = self
        self.statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    /// Called by AppKit immediately before the status-bar menu is displayed. Rebuilding here means
    /// the menu always shows the live state (e.g. "AI Processing: On/Off" after the ⌃⌥A hotkey),
    /// regardless of which Combine publisher last fired.
    func menuNeedsUpdate(_ menu: NSMenu) {
        buildMenu()
    }

    @objc private func toggleRecording() {
        dictationManager.toggleRecording()
    }

    @objc private func copyLastTranscription() {
        let text = dictationManager.currentTranscription
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        dictationManager.selectedLanguage = code
    }

    @objc private func undoLastPaste() {
        dictationManager.undoLastPaste()
    }

    private var currentPresetName: String {
        if let id = SettingsManager.shared.selectedPresetId,
           let preset = SettingsManager.shared.aiPresets.first(where: { $0.id == id }) {
            return preset.name
        }
        return "Custom"
    }

    @objc private func toggleAI() {
        SettingsManager.shared.aiProcessingEnabled.toggle()
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let presetId = sender.representedObject as? UUID else { return }
        if let preset = SettingsManager.shared.aiPresets.first(where: { $0.id == presetId }) {
            SettingsManager.shared.selectedPresetId = presetId
            SettingsManager.shared.aiSystemPrompt = preset.prompt
        }
    }

    @objc private func openHome() {
        if let window = homeWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let homeView = HomeView()
        let hostingController = NSHostingController(rootView: homeView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "My Whisper"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 560, height: 520))
        window.minSize = NSSize(width: 420, height: 300)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.homeWindow = nil
        }

        homeWindow = window
    }

    @objc private func openTranscribeFile() {
        if let window = transcribeFileWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = TranscribeFileView()
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Transcribe File"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 640, height: 520))
        window.minSize = NSSize(width: 540, height: 420)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Don't release on close so closing the window doesn't cancel the in-flight task.
        window.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.transcribeFileWindow = nil
        }

        transcribeFileWindow = window
    }

    @objc private func openOnboarding() {
        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingView(onFinish: { [weak self] in
            self?.onboardingWindow?.close()
        })
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to My Whisper"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 560))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            // Closing the window counts as completing onboarding so it won't auto-show again.
            SettingsManager.shared.hasCompletedOnboarding = true
            self?.onboardingWindow = nil
        }

        onboardingWindow = window
    }

    @objc private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "My Whisper Settings"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 820, height: 600))
        window.minSize = NSSize(width: 720, height: 520)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Clear reference when window closes
        window.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.settingsWindow = nil
        }

        settingsWindow = window
    }

    private func convertModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func retryPending(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let recording = dictationManager.pendingStore.recording(with: id) else { return }
        dictationManager.retryPending(recording)
    }

    @objc private func discardPending(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        dictationManager.pendingStore.remove(id)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Build a word-wrapped, multi-line attributed title for the menu so a long transcription
    /// stays readable instead of being cut off at one line. Caps at `maxChars` (full text is
    /// still kept in the menu item's tooltip and copied on click).
    static func wrappedMenuTitle(_ text: String, prefix: String, maxChars: Int = 280, perLine: Int = 48) -> NSAttributedString {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let capped = flat.count > maxChars
            ? String(flat.prefix(maxChars)).trimmingCharacters(in: .whitespaces) + " …"
            : flat
        var lines: [String] = []
        var current = ""
        for word in capped.split(separator: " ", omittingEmptySubsequences: true) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count > perLine && !current.isEmpty {
                lines.append(current)
                current = String(word)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(
            string: prefix + lines.joined(separator: "\n"),
            attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: paragraph]
        )
    }

    private func formatTimeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}

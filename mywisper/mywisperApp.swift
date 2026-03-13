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

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var dictationManager: DictationManager!
    private var settingsWindow: NSWindow?
    private var homeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        dictationManager = DictationManager()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "mywisper")
        }

        buildMenu()

        dictationManager.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.buildMenu()
                self?.updateIcon()
            }
        }.store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    private func updateIcon() {
        let iconName: String
        if dictationManager.isRecording {
            iconName = "mic.fill"
        } else if dictationManager.isTranscribing {
            iconName = "ellipsis.circle"
        } else {
            iconName = "mic"
        }
        statusItem.button?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "mywisper")
    }

    private func buildMenu() {
        let menu = NSMenu()

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
            let displayText: String
            if fullText.count > 60 {
                displayText = String(fullText.prefix(57)) + "..."
            } else {
                displayText = fullText
            }
            let transcriptionItem = NSMenuItem(title: "📋 \(displayText)", action: #selector(copyLastTranscription), keyEquivalent: "c")
            transcriptionItem.target = self
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

        menu.addItem(.separator())

        // Language
        let langMenu = NSMenu()
        let enItem = NSMenuItem(title: "English", action: #selector(selectEnglish), keyEquivalent: "")
        enItem.target = self
        enItem.state = dictationManager.selectedLanguage == "en-US" ? .on : .off
        langMenu.addItem(enItem)

        let ruItem = NSMenuItem(title: "Русский", action: #selector(selectRussian), keyEquivalent: "")
        ruItem.target = self
        ruItem.state = dictationManager.selectedLanguage == "ru-RU" ? .on : .off
        langMenu.addItem(ruItem)

        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        menu.addItem(langItem)

        menu.addItem(.separator())

        // Engine indicator
        let engineName = SettingsManager.shared.engine == .apple ? "Apple Speech" : "Whisper"
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

        // History
        let historyCount = TranscriptionHistory.shared.records.count
        let historyTitle = historyCount > 0 ? "History (\(historyCount))" : "History"
        let historyItem = NSMenuItem(title: historyTitle, action: #selector(openHome), keyEquivalent: "h")
        historyItem.target = self
        menu.addItem(historyItem)

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    @objc private func toggleRecording() {
        dictationManager.toggleRecording()
    }

    @objc private func copyLastTranscription() {
        let text = dictationManager.currentTranscription
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        print("mywisper: Copied transcription to clipboard")
    }

    @objc private func selectEnglish() {
        dictationManager.selectedLanguage = "en-US"
    }

    @objc private func selectRussian() {
        dictationManager.selectedLanguage = "ru-RU"
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
        window.title = "mywisper"
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

    @objc private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "mywisper Settings"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 640, height: 540))
        window.minSize = NSSize(width: 560, height: 420)
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
}

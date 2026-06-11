//
//  SettingsView.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import Carbon.HIToolbox

// MARK: - Reusable Section Card

struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }
}

// MARK: - Status Pill

struct StatusPill: View {
    let text: String
    let icon: String
    let isGood: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(isGood ? .green : .orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill((isGood ? Color.green : Color.orange).opacity(0.1))
        )
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var settings = SettingsManager.shared
    @ObservedObject var pendingStore = PendingRecordingsStore.shared
    @ObservedObject var launchAtLogin = LaunchAtLoginManager.shared
    @State private var availableModels: [(name: String, path: String)] = []
    @State private var selectedTab: SettingsTab? = .general
    @State private var availableInputDevices: [AudioInputDevice] = []
    @State private var accessibilityGranted = TextPaster.checkAccessibilityPermission()
    private let permissionTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    enum SettingsTab: String, CaseIterable, Identifiable {
        case permissions = "Permissions"
        case general = "General"
        case ai = "AI Processing"
        case hotkey = "Hotkeys"
        case about = "About"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .permissions: return "exclamationmark.shield.fill"
            case .general: return "gearshape"
            case .ai: return "brain"
            case .hotkey: return "keyboard"
            case .about: return "info.circle"
            }
        }
    }

    /// Sidebar items. The attention-grabbing Permissions row only appears while Accessibility
    /// is missing, so it can't be ignored; it disappears once the permission is granted.
    private var visibleTabs: [SettingsTab] {
        accessibilityGranted
            ? [.general, .ai, .hotkey, .about]
            : [.permissions, .general, .ai, .hotkey, .about]
    }

    var body: some View {
        NavigationSplitView {
            List(visibleTabs, selection: $selectedTab) { tab in
                sidebarRow(for: tab)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 220)
        } detail: {
            Group {
                switch selectedTab ?? .general {
                case .permissions: permissionsTab
                case .general: generalTab
                case .ai: aiProcessingTab
                case .hotkey: hotkeyTab
                case .about: aboutTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            availableModels = settings.findAvailableModels()
            availableInputDevices = AudioInputDevices.available()
            accessibilityGranted = TextPaster.checkAccessibilityPermission()
            // Land on the Permissions page first if the permission is missing.
            if !accessibilityGranted { selectedTab = .permissions }
        }
        .onReceive(permissionTimer) { _ in
            let granted = TextPaster.checkAccessibilityPermission()
            if granted != accessibilityGranted {
                accessibilityGranted = granted
                // Once granted, leave the Permissions page; if it just dropped, jump to it.
                if granted, selectedTab == .permissions { selectedTab = .general }
                if !granted { selectedTab = .permissions }
            }
        }
    }

    /// Dedicated Permissions page, reachable from the attention-grabbing orange sidebar row that
    /// appears whenever Accessibility is missing (and auto-selected on open). Makes the required
    /// action impossible to miss instead of being buried at the bottom of the Hotkeys tab.
    private var permissionsTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionCard(title: "Accessibility", icon: "exclamationmark.shield.fill",
                            subtitle: "Required for global hotkeys and auto-paste") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(accessibilityGranted ? .green : .orange)
                                .font(.system(size: 20))
                            Text(accessibilityGranted ? "Granted — you're all set." : "Not granted")
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                        }

                        if !accessibilityGranted {
                            Text("Without this, the global hotkey won't start recording and the result can't be auto-pasted. macOS resets this permission every time the app is reinstalled or updated.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            VStack(alignment: .leading, spacing: 6) {
                                Label("Click “Grant…” below", systemImage: "1.circle.fill")
                                Label("In the list, enable My Whisper", systemImage: "2.circle.fill")
                                Label("Come back — this updates automatically", systemImage: "3.circle.fill")
                            }
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                            Button {
                                TextPaster.requestAccessibilityPermission()
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Label("Grant Accessibility…", systemImage: "lock.open")
                                    .frame(maxWidth: .infinity)
                            }
                            .controlSize(.large)
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                SectionCard(title: "Microphone", icon: "mic", subtitle: "Required to record audio") {
                    Text("Requested automatically the first time you record. Manage it under System Settings → Privacy & Security → Microphone.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func sidebarRow(for tab: SettingsTab) -> some View {
        if tab == .permissions {
            Label(tab.rawValue, systemImage: tab.icon)
                .foregroundColor(.orange)
                .fontWeight(.semibold)
        } else if tab == .ai {
            Label {
                Text(tab.rawValue)
            } icon: {
                Image("openai")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
            }
        } else {
            Label(tab.rawValue, systemImage: tab.icon)
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                if !pendingStore.items.isEmpty {
                    pendingUploadsSection
                }

                SectionCard(title: "Transcription Engine", icon: "waveform", subtitle: "Choose how your speech is converted to text") {
                    Picker("Engine", selection: $settings.engine) {
                        ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    if settings.engine == .cloud {
                        Divider().padding(.vertical, 4)
                        HStack(spacing: 6) {
                            Image(systemName: settings.openAIKey.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundColor(settings.openAIKey.isEmpty ? .orange : .green)
                                .font(.system(size: 12))
                            Text(settings.openAIKey.isEmpty
                                ? "API key required — set it in the AI Processing tab"
                                : "Using OpenAI API key from AI Processing settings")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if settings.engine == .whisper {
                    whisperModelSection

                    SectionCard(title: "Live Transcription", icon: "bolt", subtitle: "Transcribe long recordings while you speak") {
                        Toggle(isOn: $settings.liveTranscriptionEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Transcribe as you speak")
                                    .font(.system(size: 13))
                                Text("Long dictations finish almost instantly — audio is processed in \(Int(settings.liveSegmentSeconds))-second segments during recording instead of all at once at the end.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }

                SectionCard(title: "Language", icon: "globe", subtitle: "Speech recognition language ('Auto' detects automatically)") {
                    Picker("Recognition Language", selection: $settings.selectedLanguage) {
                        ForEach(DictationLanguage.all) { lang in
                            Text(lang.displayName).tag(lang.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                SectionCard(title: "Microphone", icon: "mic", subtitle: "Audio input device for recording") {
                    HStack(spacing: 8) {
                        Picker("Input Device", selection: $settings.selectedInputDeviceID) {
                            Text("System Default").tag("")
                            ForEach(availableInputDevices) { device in
                                Text(device.name).tag(device.uniqueID)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()

                        Button {
                            availableInputDevices = AudioInputDevices.available()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Refresh device list")
                    }

                    if !settings.selectedInputDeviceID.isEmpty
                        && !availableInputDevices.contains(where: { $0.uniqueID == settings.selectedInputDeviceID }) {
                        Text("Selected device is unavailable — recording will use the system default.")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                }

                SectionCard(title: "Startup", icon: "power", subtitle: "Run My Whisper automatically") {
                    Toggle(isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch at login")
                                .font(.system(size: 13, weight: .medium))
                            Text("Start My Whisper automatically when you log in")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $settings.showDockIcon) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show icon in Dock")
                                .font(.system(size: 13, weight: .medium))
                            Text("Keep My Whisper reachable from the Dock even when the menu-bar icon is hidden")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }

                SectionCard(title: "Sound", icon: "speaker.wave.2", subtitle: "Audible feedback") {
                    Toggle(isOn: $settings.playStartSound) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Play a sound on start & finish")
                                .font(.system(size: 13, weight: .medium))
                            Text("A soft cue when recording starts and when the text is ready")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    if settings.playStartSound {
                        HStack(spacing: 8) {
                            Text("Sound")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Picker("", selection: $settings.selectedSoundName) {
                                Section("System") {
                                    ForEach(SoundLibrary.systemSounds, id: \.self) { name in
                                        Text(name).tag(name)
                                    }
                                }
                                if !SoundLibrary.customSounds.isEmpty {
                                    Section("Custom") {
                                        ForEach(SoundLibrary.customSounds, id: \.self) { name in
                                            Text(name).tag(name)
                                        }
                                    }
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 180)
                            .onChange(of: settings.selectedSoundName) { newValue in
                                SoundLibrary.play(named: newValue)  // preview on pick
                            }
                            Button {
                                SoundLibrary.play(named: settings.selectedSoundName)
                            } label: {
                                Label("Play", systemImage: "play.circle")
                            }
                            .controlSize(.small)
                            Spacer()
                        }

                        Divider()

                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 12))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Error sound")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Plays automatically when something fails (e.g. transcription error, dropped connection)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button {
                                SoundLibrary.playError()
                            } label: {
                                Label("Play", systemImage: "play.circle")
                            }
                            .controlSize(.small)
                        }
                    }

                    Divider()

                    Toggle(isOn: $settings.aiActionSoundEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sound on AI hotkey actions")
                                .font(.system(size: 13, weight: .medium))
                            Text("A tap when you toggle AI processing or switch AI modes with the hotkey")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }

                SectionCard(title: "Setup", icon: "checklist", subtitle: "Permissions & engine") {
                    HStack {
                        Text("Re-run the first-launch checklist to verify permissions.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button {
                            NotificationCenter.default.post(name: .showOnboardingRequested, object: nil)
                        } label: {
                            Label("Open Setup Guide", systemImage: "sparkles")
                        }
                        .controlSize(.small)
                    }
                }

                SectionCard(title: "Application", icon: "power", subtitle: "Restart or quit My Whisper") {
                    HStack {
                        Text("Use these if the menu-bar icon is hidden.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button {
                            Self.restartApp()
                        } label: {
                            Label("Restart", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        Button(role: .destructive) {
                            NSApp.terminate(nil)
                        } label: {
                            Label("Quit", systemImage: "power")
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(16)
            .onAppear { launchAtLogin.refresh() }
        }
    }

    /// Relaunch the app: spawn a fresh instance, then terminate the current one.
    static func restartApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - Pending Uploads Section

    private var pendingUploadsSection: some View {
        SectionCard(
            title: "Pending Uploads",
            icon: "tray.and.arrow.up.fill",
            subtitle: "Cloud transcriptions waiting to be retried"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 12))
                    Text("\(pendingStore.items.count) recording\(pendingStore.items.count == 1 ? "" : "s") saved after a failed upload")
                        .font(.system(size: 12))
                    Spacer()
                }

                VStack(spacing: 6) {
                    ForEach(pendingStore.items) { item in
                        pendingUploadRow(item)
                    }
                }
            }
        }
    }

    private func pendingUploadRow(_ item: PendingRecording) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(formatPendingTitle(item))
                    .font(.system(size: 12, weight: .medium))
                if let err = item.lastError {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("Awaiting retry")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button {
                requestRetry(item)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)

            Button {
                pendingStore.remove(item.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Discard")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }

    private func formatPendingTitle(_ item: PendingRecording) -> String {
        let dur = Int(item.durationSeconds.rounded())
        let durStr = String(format: "%d:%02d", dur / 60, dur % 60)
        let interval = Date().timeIntervalSince(item.createdAt)
        let ago: String
        if interval < 60 { ago = "just now" }
        else if interval < 3600 { ago = "\(Int(interval / 60))m ago" }
        else if interval < 86400 { ago = "\(Int(interval / 3600))h ago" }
        else { ago = "\(Int(interval / 86400))d ago" }
        return "\(ago) · \(durStr)"
    }

    private func requestRetry(_ item: PendingRecording) {
        // Defer to DictationManager via a NotificationCenter event so we don't
        // need to plumb a reference into SettingsView.
        NotificationCenter.default.post(
            name: .retryPendingRequested,
            object: nil,
            userInfo: ["id": item.id]
        )
    }

    // MARK: - Whisper Model Section

    @ObservedObject private var modelDownloader = ModelDownloader.shared

    @State private var isModelExpanded = false

    private var currentModelName: String {
        settings.whisperModelPath.isEmpty ? "not set" : URL(fileURLWithPath: settings.whisperModelPath).lastPathComponent
    }

    private var whisperModelSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Prominent, always-visible header so the model is easy to find and obviously tappable.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isModelExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "cpu")
                        .font(.system(size: 18))
                        .foregroundColor(.accentColor)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Whisper Model")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                        if settings.whisperModelPath.isEmpty {
                            Text("No model selected — choose one to use local Whisper")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        } else {
                            Text(currentModelName)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Text(isModelExpanded ? "Hide" : (settings.whisperModelPath.isEmpty ? "Choose" : "Change"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.accentColor)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .rotationEffect(.degrees(isModelExpanded ? 90 : 0))
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isModelExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 4) {
                ForEach(WhisperModel.all) { model in
                    whisperModelRow(model)
                }

                // Show any extra local models not in the standard list
                ForEach(availableModels.filter { local in
                    !WhisperModel.all.contains(where: { $0.fileName == URL(fileURLWithPath: local.path).lastPathComponent })
                }, id: \.path) { local in
                    let isSelected = settings.whisperModelPath == local.path
                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.4))
                            .font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(local.name)
                                .font(.system(size: 12, weight: .medium))
                            Text(local.path)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor.opacity(0.2) : Color.clear, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        settings.whisperModelPath = local.path
                    }
                }
            }

            if let error = modelDownloader.errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                    Text(error)
                        .font(.system(size: 11))
                }
                .foregroundColor(.red)
            }

            HStack(spacing: 8) {
                Button {
                    browseForModel()
                } label: {
                    Label("Browse...", systemImage: "folder")
                }
                .controlSize(.small)
            }

            Divider().padding(.vertical, 2)
            whisperBinarySection
                }
                .padding(12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(settings.whisperModelPath.isEmpty ? 0.10 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(settings.whisperModelPath.isEmpty ? 0.45 : 0.22),
                        lineWidth: settings.whisperModelPath.isEmpty ? 1.5 : 1)
        )
        .onAppear {
            // Expanded by default until a model is chosen (e.g. first launch); collapsed once set.
            isModelExpanded = settings.whisperModelPath.isEmpty
        }
        .onChange(of: settings.whisperModelPath) { newValue in
            if !newValue.isEmpty {
                withAnimation(.easeInOut(duration: 0.2)) { isModelExpanded = false }
            }
        }
    }

    private func whisperModelRow(_ model: WhisperModel) -> some View {
        let downloaded = modelDownloader.isModelDownloaded(model)
        let localPath = modelDownloader.modelPath(for: model).path
        // Also check if model exists at any scanned location
        let localMatch = availableModels.first(where: { URL(fileURLWithPath: $0.path).lastPathComponent == model.fileName })
        let effectivePath = localMatch?.path ?? localPath
        let isAvailable = downloaded || localMatch != nil
        let isSelected = settings.whisperModelPath == effectivePath
        let isDownloading = modelDownloader.downloadingModelId == model.id

        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : (isAvailable ? "circle" : "circle.dashed"))
                .foregroundColor(isSelected ? .accentColor : (isAvailable ? .secondary.opacity(0.4) : .secondary.opacity(0.2)))
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isAvailable ? .primary : .secondary)
                    Text(model.size)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Text(model.quality)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isDownloading {
                ProgressView(value: modelDownloader.downloadProgress)
                    .frame(width: 60)
                    .controlSize(.small)
            } else if !isAvailable {
                Button {
                    modelDownloader.downloadModel(model) { [self] in
                        availableModels = settings.findAvailableModels()
                    }
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .disabled(modelDownloader.downloadingModelId != nil)
            } else if isAvailable && !isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.green.opacity(0.6))
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.2) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isAvailable {
                settings.whisperModelPath = effectivePath
            }
        }
        .opacity(isAvailable ? 1.0 : 0.7)
    }

    @State private var whisperBinaryPathText: String = ""

    private var whisperBinarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("whisper-cli Binary")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            // Check all sources: user override → bundled → default path
            let resolvedPath = resolveWhisperBinaryPath()
            let binaryExists = FileManager.default.fileExists(atPath: resolvedPath)

            StatusPill(
                text: binaryExists ? "Found" : "Not found",
                icon: binaryExists ? "checkmark.circle.fill" : "xmark.circle.fill",
                isGood: binaryExists
            )

            if binaryExists {
                let isBundled = resolvedPath.contains(".app/Contents/Resources")
                Text(isBundled ? "Bundled with app" : resolvedPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                    Text("whisper-cli binary not found. Build whisper.cpp or reinstall the app.")
                        .font(.system(size: 11))
                }
                .foregroundColor(.orange)
            }
        }
    }

    private func resolveWhisperBinaryPath() -> String {
        // Check user override
        if let stored = UserDefaults.standard.string(forKey: "whisperBinaryPath"),
           FileManager.default.fileExists(atPath: stored) {
            return stored
        }
        // Check bundled binary
        if let bundled = Bundle.main.path(forResource: "whisper-cli", ofType: nil),
           FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        // Default path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Downloads/whisper.cpp/build/bin/whisper-cli"
    }

    private func browseForModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "bin")!]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a Whisper .bin model file"

        if panel.runModal() == .OK, let url = panel.url {
            settings.whisperModelPath = url.path
            availableModels = settings.findAvailableModels()
            if !availableModels.contains(where: { $0.path == url.path }) {
                availableModels.append((name: url.deletingPathExtension().lastPathComponent, path: url.path))
            }
        }
    }

    // MARK: - AI Processing Tab

    @State private var isEditingPreset = false
    @State private var editingPresetName = ""
    @State private var editingPresetPrompt = ""
    @State private var editingPresetId: UUID?
    @State private var showAPIKey = false

    // OpenAI key validation ("Test key" button)
    enum KeyTestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }
    @State private var keyTestState: KeyTestState = .idle

    private var aiProcessingTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Enable toggle
                SectionCard(title: "AI Post-Processing", icon: "brain", subtitle: "Process transcriptions with an AI model") {
                    Toggle(isOn: $settings.aiProcessingEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable AI processing")
                                .font(.system(size: 13, weight: .medium))
                            Text("Clean up, translate, or restyle transcribed text")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }

                // Custom Dictionary (works with and without AI)
                SectionCard(title: "Custom Dictionary", icon: "character.book.closed", subtitle: "Correct frequently misrecognized words") {
                    Toggle(isOn: $settings.customDictionaryEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable dictionary")
                                .font(.system(size: 13, weight: .medium))
                            Text(settings.aiProcessingEnabled || settings.engine == .cloud
                                ? "Terms guide AI/Cloud Whisper for accurate recognition"
                                : "Simple find-and-replace on transcribed text")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    if settings.customDictionaryEnabled {
                        // Vocabulary Terms (smart single-word mode)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Vocabulary Terms")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Add correct spellings of technical terms, names, etc. The AI and Cloud Whisper will recognize them automatically.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)

                            if settings.vocabularyTerms.isEmpty {
                                Text("No terms yet. Add words like Dokploy, Kubernetes, nginx...")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .padding(.vertical, 4)
                            } else {
                                VStack(spacing: 4) {
                                    ForEach(Array(settings.vocabularyTerms.enumerated()), id: \.offset) { index, _ in
                                        HStack(spacing: 8) {
                                            TextField("e.g. Dokploy, Kubernetes", text: $settings.vocabularyTerms[index])
                                                .textFieldStyle(.roundedBorder)
                                                .font(.system(size: 12))
                                            Button {
                                                settings.vocabularyTerms.remove(at: index)
                                            } label: {
                                                Image(systemName: "minus.circle.fill")
                                                    .foregroundColor(.red.opacity(0.7))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }

                            Button {
                                settings.vocabularyTerms.append("")
                            } label: {
                                Label("Add Term", systemImage: "plus")
                            }
                            .controlSize(.small)
                        }

                        Divider().padding(.vertical, 4)

                        // Legacy wrong→correct replacements (collapsible)
                        DisclosureGroup("Manual Replacements (wrong → correct)") {
                            Text("For non-AI mode: manually map misrecognized words to correct ones.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .padding(.top, 2)

                            if settings.customDictionary.isEmpty {
                                Text("No entries yet.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .padding(.vertical, 4)
                            } else {
                                VStack(spacing: 6) {
                                    HStack(spacing: 8) {
                                        Text("Wrong")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text("Correct")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Color.clear.frame(width: 24)
                                    }

                                    ForEach(Array(settings.customDictionary.enumerated()), id: \.element.id) { index, _ in
                                        HStack(spacing: 8) {
                                            TextField("wrong word", text: $settings.customDictionary[index].wrong)
                                                .textFieldStyle(.roundedBorder)
                                                .font(.system(size: 12))
                                            TextField("correct word", text: $settings.customDictionary[index].correct)
                                                .textFieldStyle(.roundedBorder)
                                                .font(.system(size: 12))
                                            Button {
                                                settings.customDictionary.remove(at: index)
                                            } label: {
                                                Image(systemName: "minus.circle.fill")
                                                    .foregroundColor(.red.opacity(0.7))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }

                            Button {
                                settings.customDictionary.append(DictionaryEntry(wrong: "", correct: ""))
                            } label: {
                                Label("Add Entry", systemImage: "plus")
                            }
                            .controlSize(.small)
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                }

                if settings.aiProcessingEnabled {
                    // API Key
                    SectionCard(title: "OpenAI API Key", icon: "key.fill") {
                        HStack(spacing: 8) {
                            ZStack {
                                if showAPIKey {
                                    TextField("sk-...", text: $settings.openAIKey)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12, design: .monospaced))
                                } else {
                                    SecureField("sk-...", text: $settings.openAIKey)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12, design: .monospaced))
                                }
                            }
                            Button {
                                showAPIKey.toggle()
                            } label: {
                                Image(systemName: showAPIKey ? "eye.slash" : "eye")
                                    .font(.system(size: 12))
                            }
                            .controlSize(.small)

                            Button {
                                testOpenAIKey()
                            } label: {
                                if keyTestState == .testing {
                                    HStack(spacing: 4) {
                                        ProgressView().controlSize(.mini)
                                        Text("Testing…")
                                    }
                                } else {
                                    Text("Test key")
                                }
                            }
                            .controlSize(.small)
                            .disabled(settings.openAIKey.isEmpty || keyTestState == .testing)
                        }

                        keyTestStatusView

                        if settings.openAIKey.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.right.circle")
                                    .font(.system(size: 10))
                                Text("Get your API key at platform.openai.com/api-keys")
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(.orange)
                        } else {
                            StatusPill(text: "API key configured", icon: "checkmark.circle.fill", isGood: true)
                        }
                    }
                    .onChange(of: settings.openAIKey) { _ in
                        // Stale result once the key is edited.
                        keyTestState = .idle
                    }

                    // Model
                    SectionCard(title: "Model", icon: "cpu", subtitle: "Choose the AI model for processing") {
                        Picker("Model", selection: $settings.openAIModel) {
                            ForEach(SettingsManager.availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .labelsHidden()

                        HStack(spacing: 12) {
                            modelHint(name: "gpt-4o-mini", desc: "Fast & cheap (default)")
                            modelHint(name: "gpt-5.4-mini", desc: "Fast, GPT-5 gen")
                            modelHint(name: "gpt-5.5", desc: "Most capable")
                        }
                    }

                    // Modes
                    SectionCard(title: "AI Mode", icon: "text.badge.star", subtitle: "How the AI reshapes your dictation before it's pasted") {
                        // Friendly explainer of the post-processing flow.
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 11))
                                .foregroundColor(.accentColor)
                                .padding(.top, 1)
                            Text("You speak → we transcribe → the selected mode rewrites the text → it gets pasted. Pick a mode below; only one is active at a time.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.bottom, 2)

                        modeList

                        HStack(spacing: 8) {
                            Button {
                                editingPresetId = nil
                                editingPresetName = ""
                                editingPresetPrompt = ""
                                isEditingPreset = true
                            } label: {
                                Label("New mode", systemImage: "plus")
                            }
                            .controlSize(.small)

                            Spacer()

                            Button {
                                settings.aiPresets = AIPromptPreset.builtIn
                                settings.selectedPresetId = nil
                                settings.aiSystemPrompt = AIPromptPreset.builtIn[0].prompt
                            } label: {
                                Label("Reset to defaults", systemImage: "arrow.counterclockwise")
                            }
                            .controlSize(.small)
                            .help("Restore the six built-in modes and remove custom ones")
                        }
                    }

                    // System Prompt (advanced)
                    SectionCard(title: "System Prompt", icon: "text.bubble", subtitle: "Advanced: the exact instructions sent to the AI") {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "lightbulb")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .padding(.top, 1)
                            Text(promptDetachedFromPreset
                                ? "These instructions are no longer tied to a saved mode. Pick a mode above to switch back, or save these as a New mode."
                                : "This is the active mode's instructions. Editing it here detaches the text from the mode (it becomes a one-off custom prompt).")
                                .font(.system(size: 11))
                                .foregroundColor(promptDetachedFromPreset ? .orange : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        TextEditor(text: $settings.aiSystemPrompt)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 80, maxHeight: 150)
                            .padding(4)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(NSColor.textBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                            .onChange(of: settings.aiSystemPrompt) { newValue in
                                if let id = settings.selectedPresetId,
                                   let preset = settings.aiPresets.first(where: { $0.id == id }),
                                   preset.prompt != newValue {
                                    settings.selectedPresetId = nil
                                }
                            }
                    }
                }
            }
            .padding(16)
        }
        .sheet(isPresented: $isEditingPreset) {
            presetEditorSheet
        }
    }

    @ViewBuilder
    private var keyTestStatusView: some View {
        switch keyTestState {
        case .idle, .testing:
            EmptyView()
        case .success:
            StatusPill(text: "Key is valid", icon: "checkmark.circle.fill", isGood: true)
        case .failure(let message):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                Text(message)
                    .font(.system(size: 11))
                    .lineLimit(2)
            }
            .foregroundColor(.red)
        }
    }

    private func testOpenAIKey() {
        let key = settings.openAIKey
        keyTestState = .testing
        OpenAIService.shared.validateKey(key) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    keyTestState = .success
                case .failure(let error):
                    keyTestState = .failure(error.localizedDescription)
                }
            }
        }
    }

    private func modelHint(name: String, desc: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(settings.openAIModel == name ? Color.accentColor : Color.secondary.opacity(0.3))
                .frame(width: 6, height: 6)
            Text("\(name) — \(desc)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Mode List

    /// True when the system prompt no longer matches any saved mode (a detached one-off prompt).
    private var promptDetachedFromPreset: Bool {
        guard let id = settings.selectedPresetId,
              let preset = settings.aiPresets.first(where: { $0.id == id }) else { return true }
        return preset.prompt != settings.aiSystemPrompt
    }

    private var modeList: some View {
        VStack(spacing: 6) {
            ForEach(settings.aiPresets) { preset in
                modeRow(preset)
            }
        }
    }

    private func modeRow(_ preset: AIPromptPreset) -> some View {
        let isSelected = settings.selectedPresetId == preset.id && !promptDetachedFromPreset
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.4))
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(preset.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                    if !preset.isBuiltIn {
                        Text("Custom")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.secondary.opacity(0.12))
                            )
                    }
                }
                Text(preset.humanDescription)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            // Explicit Edit affordance.
            Button {
                editingPresetId = preset.id
                editingPresetName = preset.name
                editingPresetPrompt = preset.prompt
                isEditingPreset = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Edit or rename this mode")

            // Delete (custom modes only — built-ins are protected).
            if !preset.isBuiltIn {
                Button {
                    settings.aiPresets.removeAll { $0.id == preset.id }
                    if settings.selectedPresetId == preset.id {
                        settings.selectedPresetId = nil
                        settings.aiSystemPrompt = AIPromptPreset.builtIn[0].prompt
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.red.opacity(0.7))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Delete this custom mode")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.1), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                settings.selectedPresetId = preset.id
                settings.aiSystemPrompt = preset.prompt
            }
        }
    }

    // MARK: - Preset Editor Sheet

    private var presetEditorSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: editingPresetId != nil ? "pencil.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
                Text(editingPresetId != nil ? "Edit Preset" : "New Preset")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("e.g. Casual Chat", text: $editingPresetName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("System Prompt")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                TextEditor(text: $editingPresetPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 120)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(NSColor.textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }

            HStack {
                Button("Cancel") {
                    isEditingPreset = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    if let existingId = editingPresetId {
                        if let index = settings.aiPresets.firstIndex(where: { $0.id == existingId }) {
                            settings.aiPresets[index] = AIPromptPreset(name: editingPresetName, prompt: editingPresetPrompt)
                            if settings.selectedPresetId == existingId {
                                settings.selectedPresetId = settings.aiPresets[index].id
                                settings.aiSystemPrompt = editingPresetPrompt
                            }
                        }
                    } else {
                        let newPreset = AIPromptPreset(name: editingPresetName, prompt: editingPresetPrompt)
                        settings.aiPresets.append(newPreset)
                    }
                    isEditingPreset = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(editingPresetName.isEmpty || editingPresetPrompt.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500, height: 400)
    }

    // MARK: - Hotkey Tab

    @State private var isRecordingHotkey = false
    @State private var isRecordingAIHotkey = false
    @State private var isRecordingCycleHotkey = false
    @State private var isRecordingCancelHotkey = false

    private var hotkeyTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                SectionCard(title: "Recording Hotkey", icon: "command", subtitle: "Trigger recording from any app") {
                    Toggle(isOn: $settings.useCustomHotkey) {
                        Text("Enable custom hotkey")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .toggleStyle(.switch)

                    if settings.useCustomHotkey {
                        HStack(spacing: 10) {
                            Text("Current:")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            if isRecordingHotkey {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text("Press a key combination...")
                                        .font(.system(size: 12, design: .monospaced))
                                }
                                .foregroundColor(.orange)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.05)))
                                )
                            } else {
                                Text(settings.customHotkeyDisplayString)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.accentColor.opacity(0.1))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
                                    )
                            }
                            Button(isRecordingHotkey ? "Cancel" : "Change...") {
                                isRecordingHotkey.toggle()
                            }
                            .controlSize(.small)
                        }

                        Text("Use any key with at least one modifier (⌃ ⌥ ⇧ ⌘)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .background(
                    HotkeyRecorderView(
                        isRecording: $isRecordingHotkey,
                        onHotkeyRecorded: { keyCode, modifiers in
                            settings.customHotkeyKeyCode = keyCode
                            settings.customHotkeyModifiers = modifiers
                            isRecordingHotkey = false
                        }
                    )
                    .frame(width: 0, height: 0)
                )

                SectionCard(title: "Double-tap Fn", icon: "fn", subtitle: "Experimental alternative trigger") {
                    Toggle(isOn: $settings.useDoubleTapFn) {
                        Text("Double-tap Fn to toggle recording")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .toggleStyle(.switch)

                    if settings.useDoubleTapFn {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Speed:")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Slider(value: $settings.hotkeyDoubleTapInterval, in: 0.2...0.8, step: 0.05)
                                    .frame(maxWidth: 180)
                                Text("\(String(format: "%.2f", settings.hotkeyDoubleTapInterval))s")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 44)
                            }

                            HStack(spacing: 4) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 10))
                                Text("Set Fn key to \"Do Nothing\" in System Settings > Keyboard")
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(.secondary)
                        }
                    }
                }

                SectionCard(title: "Toggle AI Processing", icon: "brain", subtitle: "Turn AI post-processing on or off from any app") {
                    Toggle(isOn: $settings.useAIToggleHotkey) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable AI on/off hotkey")
                                .font(.system(size: 13, weight: .medium))
                            Text("Flip AI post-processing without opening the menu")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    if settings.useAIToggleHotkey {
                        HStack(spacing: 10) {
                            Text("Current:")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            if isRecordingAIHotkey {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text("Press a key combination...")
                                        .font(.system(size: 12, design: .monospaced))
                                }
                                .foregroundColor(.orange)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.05)))
                                )
                            } else {
                                Text(settings.aiToggleHotkeyDisplayString)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.purple.opacity(0.1))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                                    )
                            }
                            Button(isRecordingAIHotkey ? "Cancel" : "Change...") {
                                isRecordingAIHotkey.toggle()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .background(
                    HotkeyRecorderView(
                        isRecording: $isRecordingAIHotkey,
                        onHotkeyRecorded: { keyCode, modifiers in
                            settings.aiToggleHotkeyKeyCode = keyCode
                            settings.aiToggleHotkeyModifiers = modifiers
                            isRecordingAIHotkey = false
                        }
                    )
                    .frame(width: 0, height: 0)
                )

                SectionCard(title: "Cycle AI Mode", icon: "arrow.triangle.2.circlepath", subtitle: "Switch to the next AI mode from any app") {
                    Toggle(isOn: $settings.useCycleModeHotkey) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable cycle-mode hotkey")
                                .font(.system(size: 13, weight: .medium))
                            Text("Step through your AI modes (Clean Up, Translate, …) in order")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    if settings.useCycleModeHotkey {
                        HStack(spacing: 10) {
                            Text("Current:")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            if isRecordingCycleHotkey {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text("Press a key combination...")
                                        .font(.system(size: 12, design: .monospaced))
                                }
                                .foregroundColor(.orange)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.05)))
                                )
                            } else {
                                Text(settings.cycleModeHotkeyDisplayString)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.purple.opacity(0.1))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                                    )
                            }
                            Button(isRecordingCycleHotkey ? "Cancel" : "Change...") {
                                isRecordingCycleHotkey.toggle()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .background(
                    HotkeyRecorderView(
                        isRecording: $isRecordingCycleHotkey,
                        onHotkeyRecorded: { keyCode, modifiers in
                            settings.cycleModeHotkeyKeyCode = keyCode
                            settings.cycleModeHotkeyModifiers = modifiers
                            isRecordingCycleHotkey = false
                        }
                    )
                    .frame(width: 0, height: 0)
                )

                SectionCard(title: "Cancel Hotkey", icon: "xmark.circle", subtitle: "Abort recording or transcription") {
                    HStack(spacing: 10) {
                        Text("Current:")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        if isRecordingCancelHotkey {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("Press any key...")
                                    .font(.system(size: 12, design: .monospaced))
                            }
                            .foregroundColor(.orange)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.05)))
                            )
                        } else {
                            Text(settings.cancelHotkeyDisplayString)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.red.opacity(0.1))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.red.opacity(0.2), lineWidth: 1)
                                )
                        }
                        Button(isRecordingCancelHotkey ? "Cancel" : "Change...") {
                            isRecordingCancelHotkey.toggle()
                        }
                        .controlSize(.small)
                    }

                    Text("Press this key during recording or transcription to cancel and discard")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .background(
                    CancelHotkeyRecorderView(
                        isRecording: $isRecordingCancelHotkey,
                        onKeyRecorded: { keyCode in
                            settings.cancelHotkeyKeyCode = keyCode
                            isRecordingCancelHotkey = false
                        }
                    )
                    .frame(width: 0, height: 0)
                )

                SectionCard(title: "Menu Bar", icon: "menubar.rectangle") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Click the mic icon in the menu bar to start/stop recording.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        HStack(spacing: 4) {
                            Image(systemName: "command")
                                .font(.system(size: 10))
                            Text("R when menu is open")
                                .font(.system(size: 12))
                        }
                        .foregroundColor(.secondary)
                    }
                }

                SectionCard(title: "Permissions", icon: "lock.shield", subtitle: "Required for the app to work") {
                    let accessibilityGranted = AXIsProcessTrusted()

                    VStack(alignment: .leading, spacing: 8) {
                        // Microphone
                        HStack(spacing: 8) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 12))
                                .frame(width: 20)
                            Text("Microphone — required for recording")
                                .font(.system(size: 12))
                            Spacer()
                            Text("Prompted on first use")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }

                        Divider()

                        // Accessibility
                        HStack(spacing: 8) {
                            Image(systemName: accessibilityGranted ? "checkmark.shield.fill" : "xmark.shield.fill")
                                .font(.system(size: 12))
                                .foregroundColor(accessibilityGranted ? .green : .red)
                                .frame(width: 20)
                            Text("Accessibility — global hotkeys & auto-paste")
                                .font(.system(size: 12))
                            Spacer()
                            StatusPill(
                                text: accessibilityGranted ? "Granted" : "Not Granted",
                                icon: accessibilityGranted ? "checkmark.circle.fill" : "xmark.circle.fill",
                                isGood: accessibilityGranted
                            )
                        }

                        if !accessibilityGranted {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Without Accessibility:")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.orange)
                                Text("  - Global hotkeys won't work")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Text("  - Auto-paste won't work (use Cmd+V manually)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Text("  - Recording via menu button still works")
                                    .font(.system(size: 11))
                                    .foregroundColor(.green)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text("How to fix:")
                                    .font(.system(size: 11, weight: .medium))
                                Text("1. System Settings > Privacy & Security > Accessibility")
                                    .font(.system(size: 11))
                                Text("2. Remove old 'My Whisper' entry if present (−)")
                                    .font(.system(size: 11))
                                Text("3. Add My Whisper from /Applications (+)")
                                    .font(.system(size: 11))
                                Text("4. Restart the app")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.orange)
                            }
                            .foregroundColor(.secondary)

                            HStack(spacing: 8) {
                                Button {
                                    TextPaster.requestAccessibilityPermission()
                                } label: {
                                    Label("Request Permission", systemImage: "lock.open")
                                }
                                .controlSize(.small)

                                Button {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                                } label: {
                                    Label("Open System Settings", systemImage: "gear")
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - About Tab

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(version) (\(build))"
    }

    private var aboutTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Hero banner — switches with the system light/dark appearance and links to the
                // product site. (Asset "Banner" provides both luminosity variants.)
                Link(destination: URL(string: "https://mywhisper.cloud/")!) {
                    Image("Banner")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Visit mywhisper.cloud")

                SectionCard(title: "My Whisper", icon: "mic.fill", subtitle: appVersion) {
                    Text("Local-first menu bar dictation. Record speech with a global hotkey, transcribe it on-device with Whisper (or Apple Speech / Cloud), optionally refine it with AI, and paste it into the focused field.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SectionCard(title: "Resources", icon: "link", subtitle: "Help & background") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            NotificationCenter.default.post(name: .showOnboardingRequested, object: nil)
                        } label: {
                            Label("Open Setup Guide", systemImage: "sparkles")
                        }
                        .controlSize(.small)

                        Link(destination: URL(string: "https://github.com/ggerganov/whisper.cpp")!) {
                            Label("whisper.cpp on GitHub", systemImage: "arrow.up.right.square")
                        }
                        .font(.system(size: 12))

                        Link(destination: URL(string: "https://platform.openai.com/api-keys")!) {
                            Label("OpenAI API keys", systemImage: "arrow.up.right.square")
                        }
                        .font(.system(size: 12))
                    }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Hotkey Recorder

struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onHotkeyRecorded: (UInt16, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.onHotkeyRecorded = onHotkeyRecorded
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.isRecordingHotkey = isRecording
        nsView.onHotkeyRecorded = onHotkeyRecorded
        if isRecording {
            nsView.startMonitoring()
        } else {
            nsView.stopMonitoring()
        }
    }
}

class HotkeyRecorderNSView: NSView {
    var isRecordingHotkey = false
    var onHotkeyRecorded: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    private var monitor: Any?

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isRecordingHotkey else { return event }

            let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
            guard !mods.isEmpty else { return event }
            guard event.keyCode != 56 && event.keyCode != 58 && event.keyCode != 59 && event.keyCode != 55 else {
                return event
            }

            self.onHotkeyRecorded?(event.keyCode, mods)
            return nil
        }
    }

    func stopMonitoring() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        stopMonitoring()
    }
}

// MARK: - Cancel Hotkey Recorder (single key, no modifiers required)

struct CancelHotkeyRecorderView: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onKeyRecorded: (UInt16) -> Void

    func makeNSView(context: Context) -> CancelHotkeyRecorderNSView {
        let view = CancelHotkeyRecorderNSView()
        view.onKeyRecorded = onKeyRecorded
        return view
    }

    func updateNSView(_ nsView: CancelHotkeyRecorderNSView, context: Context) {
        nsView.isRecordingKey = isRecording
        nsView.onKeyRecorded = onKeyRecorded
        if isRecording {
            nsView.startMonitoring()
        } else {
            nsView.stopMonitoring()
        }
    }
}

class CancelHotkeyRecorderNSView: NSView {
    var isRecordingKey = false
    var onKeyRecorded: ((UInt16) -> Void)?
    private var monitor: Any?

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isRecordingKey else { return event }
            // Accept any key (no modifier requirement)
            self.onKeyRecorded?(event.keyCode)
            return nil
        }
    }

    func stopMonitoring() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        stopMonitoring()
    }
}

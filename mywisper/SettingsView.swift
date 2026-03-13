//
//  SettingsView.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import SwiftUI
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
    @State private var availableModels: [(name: String, path: String)] = []
    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case ai = "AI Processing"
        case hotkey = "Hotkey"

        var icon: String {
            switch self {
            case .general: return "gear"
            case .ai: return "brain"
            case .hotkey: return "keyboard"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    sidebarButton(for: tab)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 160)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Content
            Group {
                switch selectedTab {
                case .general: generalTab
                case .ai: aiProcessingTab
                case .hotkey: hotkeyTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 620, minHeight: 480)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            availableModels = settings.findAvailableModels()
        }
    }

    private func sidebarButton(for tab: SettingsTab) -> some View {
        HStack(spacing: 8) {
            if tab == .ai {
                Image("openai")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .frame(width: 20)
            } else {
                Image(systemName: tab.icon)
                    .font(.system(size: 13))
                    .frame(width: 20)
            }
            Text(tab.rawValue)
                .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
            Spacer()
        }
        .foregroundColor(selectedTab == tab ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selectedTab == tab ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                SectionCard(title: "Transcription Engine", icon: "waveform", subtitle: "Choose how your speech is converted to text") {
                    Picker("Engine", selection: $settings.engine) {
                        ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    if settings.engine == .whisper {
                        Divider().padding(.vertical, 4)
                        whisperModelSection
                    }
                }

                SectionCard(title: "Language", icon: "globe", subtitle: "Speech recognition language") {
                    Picker("Recognition Language", selection: $settings.selectedLanguage) {
                        HStack(spacing: 6) {
                            Text("English")
                        }.tag("en-US")
                        HStack(spacing: 6) {
                            Text("Русский")
                        }.tag("ru-RU")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .padding(16)
        }
    }

    // MARK: - Whisper Model Section

    @ObservedObject private var modelDownloader = ModelDownloader.shared

    private var whisperModelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Model")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

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

            if !settings.whisperModelPath.isEmpty {
                let fileName = URL(fileURLWithPath: settings.whisperModelPath).lastPathComponent
                StatusPill(text: "Selected: \(fileName)", icon: "checkmark.circle.fill", isGood: true)
            }

            Divider().padding(.vertical, 2)
            whisperBinarySection
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
                        }

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

                    // Model
                    SectionCard(title: "Model", icon: "cpu", subtitle: "Choose the AI model for processing") {
                        Picker("Model", selection: $settings.openAIModel) {
                            ForEach(SettingsManager.availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .labelsHidden()

                        HStack(spacing: 12) {
                            modelHint(name: "gpt-4o-mini", desc: "Fast & cheap")
                            modelHint(name: "gpt-4o", desc: "Most capable")
                        }
                    }

                    // Presets
                    SectionCard(title: "Mode Presets", icon: "text.badge.star", subtitle: "Quick-switch between processing modes") {
                        presetGrid

                        HStack(spacing: 8) {
                            Button {
                                editingPresetId = nil
                                editingPresetName = ""
                                editingPresetPrompt = ""
                                isEditingPreset = true
                            } label: {
                                Label("Add Custom", systemImage: "plus")
                            }
                            .controlSize(.small)

                            Button {
                                settings.aiPresets = AIPromptPreset.builtIn
                                settings.selectedPresetId = nil
                                settings.aiSystemPrompt = AIPromptPreset.builtIn[0].prompt
                            } label: {
                                Label("Reset", systemImage: "arrow.counterclockwise")
                            }
                            .controlSize(.small)
                        }
                    }

                    // System Prompt
                    SectionCard(title: "System Prompt", icon: "text.bubble", subtitle: "Instructions for the AI model") {
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

    // MARK: - Preset Grid

    private var presetGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(settings.aiPresets) { preset in
                presetCard(preset)
            }
        }
    }

    private func presetCard(_ preset: AIPromptPreset) -> some View {
        let isSelected = settings.selectedPresetId == preset.id
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Text(preset.prompt.prefix(40) + "...")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            // Edit button
            Menu {
                Button("Edit") {
                    editingPresetId = preset.id
                    editingPresetName = preset.name
                    editingPresetPrompt = preset.prompt
                    isEditingPreset = true
                }
                if !AIPromptPreset.builtIn.contains(where: { $0.name == preset.name }) {
                    Divider()
                    Button("Delete", role: .destructive) {
                        settings.aiPresets.removeAll { $0.id == preset.id }
                        if settings.selectedPresetId == preset.id {
                            settings.selectedPresetId = nil
                            settings.aiSystemPrompt = AIPromptPreset.builtIn[0].prompt
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
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

                SectionCard(title: "AI Toggle Hotkey", icon: "brain", subtitle: "Toggle AI processing on/off from any app") {
                    Toggle(isOn: $settings.useAIToggleHotkey) {
                        Text("Enable AI toggle hotkey")
                            .font(.system(size: 13, weight: .medium))
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
                                Text("2. Remove old 'mywisper' entry if present (−)")
                                    .font(.system(size: 11))
                                Text("3. Add mywisper from /Applications (+)")
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

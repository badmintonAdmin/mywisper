//
//  MainWindowView.swift
//  mywisper
//
//  The app's main window: a sidebar (Record / Transcribe File / History + Settings),
//  a central Record screen showing the live pipeline (engine → AI → language), and a
//  collapsible History panel on the right. Opened on dock-reopen; Settings stays a
//  separate window. Reuses TranscribeFileView, HomeView, DictationManager,
//  FileTranscriptionService.
//
//  Styling goal: soft, light, "cards on a tinted background" look — white cards
//  (controlBackgroundColor) with gentle shadows over the window background, no hard
//  strokes. Record and Transcribe File are separate cards, as in the reference.
//

import SwiftUI
import AppKit

// MARK: - Navigation

enum MainTab: String, CaseIterable, Identifiable {
    case record, transcribeFile, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .record: return "Record"
        case .transcribeFile: return "Transcribe File"
        case .history: return "History"
        }
    }
    var icon: String {
        switch self {
        case .record: return "mic.fill"
        case .transcribeFile: return "folder"
        case .history: return "clock"
        }
    }
}

/// Shared router so menu items / notifications can open the main window on a given tab.
final class MainWindowNav: ObservableObject {
    static let shared = MainWindowNav()
    @Published var selectedTab: MainTab = .record
}

// MARK: - Soft card style

private extension View {
    func softCard(cornerRadius: CGFloat = 16) -> some View {
        self.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
        )
    }
}

// MARK: - Styled dropdown (soft white field, leading icon, trailing chevron)

private struct DropdownField<T: Hashable>: View {
    let icon: String
    @Binding var selection: T
    let options: [(String, T)]

    private var currentLabel: String {
        options.first(where: { $0.1 == selection })?.0 ?? ""
    }

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in
                let opt = options[i]
                Button {
                    selection = opt.1
                } label: {
                    if opt.1 == selection {
                        Label(opt.0, systemImage: "checkmark")
                    } else {
                        Text(opt.0)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 12)).foregroundColor(.secondary)
                Text(currentLabel).font(.system(size: 13)).foregroundColor(.primary).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .focusable(false)
    }
}

// MARK: - Main Window

struct MainWindowView: View {
    @ObservedObject var dictation: DictationManager
    @ObservedObject private var nav = MainWindowNav.shared
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var history = TranscriptionHistory.shared

    @State private var showHistory = true

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    // Click on empty space drops focus from the History search field.
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            LinearGradient(colors: [Color.accentColor.opacity(0.05), .clear],
                           startPoint: .topLeading, endPoint: .bottom)
                .allowsHitTesting(false)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                sidebar.frame(width: 208)

                HStack(alignment: .top, spacing: 14) {
                    tabContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if nav.selectedTab == .record {
                        if showHistory {
                            HistorySidePanel(history: history,
                                             onCollapse: { withAnimation(.easeInOut(duration: 0.22)) { showHistory = false } },
                                             onViewAll: { nav.selectedTab = .history })
                                .frame(width: 300)
                                .frame(maxHeight: .infinity)
                                .softCard()
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        } else {
                            expandHistoryButton
                                .transition(.opacity)
                        }
                    }
                }
                .padding(16)
            }
        }
        // Min matches the window's contentMinSize so the layout can never cram to the edges.
        .frame(minWidth: 1160, idealWidth: 1240, maxWidth: .infinity,
               minHeight: 740, idealHeight: 800, maxHeight: .infinity)
    }

    // MARK: Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch nav.selectedTab {
        case .record:
            RecordScreen(dictation: dictation, onPickedFile: { url in
                nav.selectedTab = .transcribeFile
                Task { _ = await FileTranscriptionService.shared.start(sourceURL: url, language: dictation.selectedLanguage) }
            })
        case .transcribeFile:
            TranscribeFileView()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .softCard()
        case .history:
            HomeView()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .softCard()
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.12)))
                (Text("My ").foregroundColor(.accentColor) + Text("Whisper").foregroundColor(.primary))
                    .font(.system(size: 17, weight: .semibold))
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 20)

            ForEach(MainTab.allCases) { tab in
                SidebarRow(title: tab.title, icon: tab.icon, selected: nav.selectedTab == tab) {
                    nav.selectedTab = tab
                }
            }

            SidebarRow(title: "Settings", icon: "gearshape", selected: false) {
                NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
            }

            Spacer()

            HStack(spacing: 9) {
                Circle()
                    .fill(dictation.isRecording ? Color.red : (dictation.isTranscribing ? Color.orange : Color.green))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("My Whisper").font(.system(size: 12, weight: .medium))
                    Text(appVersion).font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        return "v\(v)"
    }

    // MARK: Collapsed-history expand button (small pill at top)

    private var expandHistoryButton: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { showHistory = true }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "clock").font(.system(size: 12))
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .softCard(cornerRadius: 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Show history")
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Sidebar Row

private struct SidebarRow: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 20)
                    .foregroundColor(selected ? .accentColor : .secondary)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .accentColor : .primary.opacity(0.85))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : (hovering ? Color.secondary.opacity(0.08) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)               // no persistent macOS focus ring on the active item
        .padding(.horizontal, 10)
        .onHover { hovering = $0 }
    }
}

// MARK: - Record Screen (two separate cards: Record + Transcribe File)

private struct RecordScreen: View {
    @ObservedObject var dictation: DictationManager
    let onPickedFile: (URL) -> Void

    @ObservedObject private var settings = SettingsManager.shared
    @State private var elapsed: TimeInterval = 0
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var fileHovering = false

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var statusText: String {
        if dictation.isTranscribing { return "Transcribing…" }
        if dictation.isRecording { return "Recording…" }
        return "Ready to start"
    }

    var body: some View {
        VStack(spacing: 14) {
            recordCard
            transcribeFileCard
            Spacer(minLength: 0)
        }
        .onReceive(ticker) { _ in if dictation.isRecording { elapsed += 1 } }
        .onChange(of: dictation.isRecording) { recording in if recording { elapsed = 0 } }
        .onAppear { inputDevices = AudioInputDevices.available() }
    }

    // MARK: Record card

    private var recordCard: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Record").font(.system(size: 24, weight: .bold))
                Text("Start recording to transcribe your speech")
                    .font(.system(size: 13)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            micHero

            VStack(spacing: 4) {
                Text(timeString(elapsed))
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.85))
                WaveformBar(active: dictation.isRecording)
                    .frame(height: 24).frame(maxWidth: 320)
                    .padding(.top, 4)
                Text(statusText).font(.system(size: 13)).foregroundColor(.secondary)
                    .padding(.top, 4)
            }

            controlsRow
            pipelineLine
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .softCard()
    }

    private var micHero: some View {
        let ringColor = dictation.isRecording ? Color.red : Color(red: 0.36, green: 0.56, blue: 0.98)
        let core = dictation.isRecording
            ? [Color(red: 0.97, green: 0.32, blue: 0.38), Color(red: 0.93, green: 0.42, blue: 0.56)]
            : [Color(red: 0.44, green: 0.64, blue: 1.0), Color(red: 0.23, green: 0.46, blue: 0.95)]
        return Button(action: { dictation.toggleRecording() }) {
            ZStack {
                // Two halo rings, different opacity (outer fainter).
                Circle().fill(ringColor.opacity(0.06)).frame(width: 150, height: 150)
                    .scaleEffect(dictation.isRecording ? 1.06 : 1.0)
                    .animation(dictation.isRecording
                               ? .easeInOut(duration: 0.95).repeatForever(autoreverses: true)
                               : .easeInOut(duration: 0.25), value: dictation.isRecording)
                Circle().fill(ringColor.opacity(0.13)).frame(width: 116, height: 116)
                // Gradient core.
                Circle()
                    .fill(LinearGradient(colors: core, startPoint: .top, endPoint: .bottom))
                    .frame(width: 92, height: 92)
                    .shadow(color: ringColor.opacity(0.35), radius: 12, y: 4)
                Image(systemName: dictation.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(.white)
            }
            .animation(.easeInOut(duration: 0.25), value: dictation.isRecording)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(dictation.isTranscribing)
    }

    private var controlsRow: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            DropdownField(icon: "mic", selection: $settings.selectedInputDeviceID,
                          options: [("Default Microphone", "")] + inputDevices.map { ($0.name, $0.uniqueID) })
                .frame(width: 200)
            recordButton
            DropdownField(icon: "globe", selection: $dictation.selectedLanguage,
                          options: DictationLanguage.all.map { ($0.displayName, $0.code) })
                .frame(width: 200)
            Spacer(minLength: 0)
        }
    }

    private var recordButton: some View {
        Button(action: { dictation.toggleRecording() }) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .frame(width: 62, height: 50)
                    .shadow(color: .black.opacity(0.08), radius: 5, y: 1)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
                if dictation.isRecording {
                    RoundedRectangle(cornerRadius: 5).fill(Color.red).frame(width: 18, height: 18)
                } else {
                    Circle().fill(Color.red).frame(width: 22, height: 22)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: dictation.isRecording)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(dictation.isTranscribing)
    }

    // MARK: Pipeline (plain text)

    private var pipelineLine: some View {
        HStack(spacing: 7) {
            Image(systemName: engineIcon).font(.system(size: 11))
            Text(engineText)
            chainDot
            Image(systemName: settings.aiProcessingEnabled ? "brain" : "brain.head.profile")
                .font(.system(size: 11))
                .foregroundColor(settings.aiProcessingEnabled ? .purple : .secondary)
            Text(aiText)
            chainDot
            Image(systemName: "globe").font(.system(size: 11))
            Text(DictationLanguage.displayName(for: dictation.selectedLanguage))
        }
        .font(.system(size: 12))
        .foregroundColor(.secondary)
    }

    private var chainDot: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary.opacity(0.45))
    }

    private var engineIcon: String {
        switch settings.engine {
        case .cloud: return "cloud"
        case .whisper: return "waveform"
        case .apple: return "apple.logo"
        }
    }

    private var engineText: String {
        switch settings.engine {
        case .cloud: return "Cloud Whisper"
        case .apple: return "Apple Speech"
        case .whisper:
            let model = modelShortName(settings.whisperModelPath)
            return model.isEmpty ? "Whisper" : "Whisper (\(model))"
        }
    }

    private var aiText: String {
        guard settings.aiProcessingEnabled else { return "AI off" }
        if let id = settings.selectedPresetId,
           let preset = settings.aiPresets.first(where: { $0.id == id }) {
            return preset.name
        }
        return "AI on"
    }

    private func modelShortName(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        var n = (path as NSString).lastPathComponent
        n = n.replacingOccurrences(of: "ggml-", with: "")
        if let dot = n.lastIndex(of: ".") { n = String(n[..<dot]) }
        return n
    }

    // MARK: Transcribe File card (separate)

    private var transcribeFileCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcribe File").font(.system(size: 15, weight: .semibold))
            Text("Upload an audio or video file to transcribe")
                .font(.system(size: 11)).foregroundColor(.secondary)

            Button(action: { showOpenPanel() }) {
                VStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 22)).foregroundColor(.accentColor)
                    Text("Drag and drop your file here").font(.system(size: 13, weight: .medium))
                    Text("or click to browse").font(.system(size: 12)).foregroundColor(.accentColor)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(fileHovering ? Color.accentColor.opacity(0.06) : Color.secondary.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5]))
                        .foregroundColor(.secondary.opacity(0.28))
                )
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onDrop(of: ["public.file-url"], isTargeted: $fileHovering) { providers in handleDrop(providers) }

            Text("Supports MP3, WAV, M4A, MP4, MOV and more")
                .font(.system(size: 10)).foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .softCard()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url = url { DispatchQueue.main.async { onPickedFile(url) } }
        }
        return true
    }

    private func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url { onPickedFile(url) }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

// MARK: - Waveform (smooth, continuous)

private struct WaveformBar: View {
    let active: Bool
    private let count = 30
    private let idle: CGFloat = 5
    private let maxH: CGFloat = 24

    var body: some View {
        TimelineView(.animation(paused: !active)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(Color.accentColor.opacity(active ? 0.6 : 0.22))
                        .frame(width: 3, height: barHeight(i, t))
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.2), value: active)
        }
    }

    private func barHeight(_ i: Int, _ t: Double) -> CGFloat {
        guard active else { return idle + CGFloat(i % 3) * 2 }
        let phase = Double(i) * 0.55
        let wave = sin(t * 5.5 + phase) * 0.6 + sin(t * 9 + phase * 1.7) * 0.4
        let norm = CGFloat(wave * 0.5 + 0.5)
        return idle + (maxH - idle) * norm
    }
}

// MARK: - History Side Panel (collapsible)

private struct HistorySidePanel: View {
    @ObservedObject var history: TranscriptionHistory
    let onCollapse: () -> Void
    let onViewAll: () -> Void

    @State private var search = ""
    @State private var copiedId: UUID?

    private var records: [TranscriptionRecord] {
        let base = search.isEmpty ? history.records
            : history.records.filter { $0.text.localizedCaseInsensitiveContains(search) }
        return Array(base.prefix(20))
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("History").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: onCollapse) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Hide history")
            }
            .padding(.top, 16)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(.secondary)
                TextField("Search transcripts…", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.08)))

            if records.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 24, weight: .light)).foregroundColor(.accentColor.opacity(0.5))
                    Text(search.isEmpty ? "No transcriptions yet" : "No results")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(records) { rec in historyRow(rec) }
                    }
                }
                Button(action: onViewAll) {
                    Label("View All", systemImage: "list.bullet")
                        .font(.system(size: 12)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .focusable(false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func historyRow(_ rec: TranscriptionRecord) -> some View {
        Button(action: { copy(rec) }) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: copiedId == rec.id ? "checkmark.circle.fill" : (rec.isFile ? "doc.text" : "mic.fill"))
                    .font(.system(size: 13))
                    .foregroundColor(copiedId == rec.id ? .green : .accentColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rec.text).font(.system(size: 12)).lineLimit(2)
                        .foregroundColor(.primary).multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if rec.isFile {
                            HStack(spacing: 3) {
                                Image(systemName: "doc.text").font(.system(size: 8))
                                Text("File").font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundColor(.blue)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue.opacity(0.12)))
                        }
                        Text(Self.relative.localizedString(for: rec.date, relativeTo: Date()))
                        Text("·")
                        Text(String(format: "%.0fs", rec.durationSeconds))
                    }
                    .font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Copy to clipboard")
        .contextMenu {
            Button { copy(rec) } label: { Label("Copy text", systemImage: "doc.on.doc") }
            // When AI post-processing changed the text, let the user grab the original dictation too.
            if rec.aiProcessed, let raw = rec.rawText, raw != rec.text {
                Button { copyOriginal(rec) } label: { Label("Copy original (before AI)", systemImage: "text.quote") }
            }
            Divider()
            Button(role: .destructive) { history.delete(id: rec.id) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func copy(_ rec: TranscriptionRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rec.text, forType: .string)
        copiedId = rec.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedId == rec.id { copiedId = nil }
        }
    }

    /// Copy the original, pre-AI dictation (falls back to the final text if none was stored).
    private func copyOriginal(_ rec: TranscriptionRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rec.rawText ?? rec.text, forType: .string)
        copiedId = rec.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedId == rec.id { copiedId = nil }
        }
    }
}

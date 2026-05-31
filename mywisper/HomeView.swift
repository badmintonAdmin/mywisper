//
//  HomeView.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import SwiftUI

struct HomeView: View {
    @ObservedObject var history = TranscriptionHistory.shared
    @State private var copiedId: UUID?
    @State private var searchText = ""
    @State private var showClearConfirm = false

    private var filteredRecords: [TranscriptionRecord] {
        if searchText.isEmpty { return history.records }
        return history.records.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection
            if !history.records.isEmpty {
                statsSection
            }
            searchBar
            Divider()

            // Content
            if filteredRecords.isEmpty {
                emptyState
            } else {
                recordsList
            }
        }
        .frame(minWidth: 520, minHeight: 440)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("History")
                    .font(.title)
                    .fontWeight(.bold)
                if !history.records.isEmpty {
                    Text("\(history.records.count) transcription\(history.records.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if !history.records.isEmpty {
                Button {
                    showClearConfirm = true
                } label: {
                    Label("Clear All", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .alert("Clear all transcriptions?", isPresented: $showClearConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Clear All", role: .destructive) { history.clearAll() }
                } message: {
                    Text("This action cannot be undone.")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    // MARK: - Statistics

    private var statsSection: some View {
        let stats = history.stats
        return HStack(spacing: 10) {
            statCard(title: "Transcriptions", value: "\(stats.totalTranscriptions)", icon: "text.bubble")
            statCard(title: "Words", value: "\(stats.totalWords)", icon: "textformat.123")
            statCard(title: "Audio", value: Self.formatDuration(stats.totalAudioSeconds), icon: "waveform")
            statCard(title: "Time Saved", value: Self.formatDuration(stats.timeSavedSeconds), icon: "clock.arrow.circlepath")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func statCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(size: 16, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    /// Compact human-readable duration: "45s", "3m 12s", "1h 5m".
    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            TextField("Search transcriptions...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: searchText.isEmpty ? "waveform.and.mic" : "magnifyingglass")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(.accentColor.opacity(0.6))
            }
            VStack(spacing: 6) {
                Text(searchText.isEmpty ? "No transcriptions yet" : "No results found")
                    .font(.title3)
                    .fontWeight(.medium)
                Text(searchText.isEmpty
                     ? "Press your hotkey to start recording.\nTranscriptions will appear here."
                     : "Try a different search term.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Records List

    private var recordsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredRecords) { record in
                    TranscriptionRow(
                        record: record,
                        isCopied: copiedId == record.id,
                        onCopy: { copyText(record) },
                        onDelete: { withAnimation(.easeOut(duration: 0.2)) { history.delete(id: record.id) } }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    private func copyText(_ record: TranscriptionRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.text, forType: .string)
        copiedId = record.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedId == record.id { copiedId = nil }
        }
    }
}

// MARK: - Transcription Row

struct TranscriptionRow: View {
    let record: TranscriptionRecord
    let isCopied: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var showOriginal = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Main text
            Text(record.text)
                .font(.system(size: 13))
                .lineSpacing(3)
                .lineLimit(isHovered ? nil : 3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Original text (AI processed)
            if record.aiProcessed, let rawText = record.rawText, rawText != record.text {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showOriginal.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showOriginal ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                        Text("Original text")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                if showOriginal {
                    Text(rawText)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.06))
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            // Metadata row
            HStack(spacing: 6) {
                MetadataBadge(
                    text: Self.relativeFormatter.localizedString(for: record.date, relativeTo: Date()),
                    icon: "clock"
                )
                .help(Self.dateFormatter.string(from: record.date))

                MetadataBadge(
                    text: record.engine == "cloud" ? "Cloud" : (record.engine == "whisper" ? "Whisper" : "Apple"),
                    icon: record.engine == "cloud" ? "cloud" : (record.engine == "whisper" ? "waveform" : "apple.logo")
                )

                MetadataBadge(
                    text: String(format: "%.1fs", record.durationSeconds),
                    icon: "timer"
                )

                MetadataBadge(
                    text: record.language == DictationLanguage.autoCode
                        ? "AUTO"
                        : String(record.language.prefix(2)).uppercased(),
                    icon: "globe"
                )

                if record.aiProcessed {
                    MetadataBadge(
                        text: record.aiModel ?? "GPT",
                        icon: "brain",
                        tint: .purple
                    )
                }

                Spacer()

                // Action buttons
                if isHovered || isCopied {
                    HStack(spacing: 2) {
                        Button(action: onCopy) {
                            Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc")
                                .font(.system(size: 12))
                                .foregroundColor(isCopied ? .green : .secondary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help("Copy to clipboard")

                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help("Delete")
                    }
                    .transition(.opacity)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color(NSColor.controlBackgroundColor) : Color(NSColor.controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isHovered ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}

// MARK: - Metadata Badge

struct MetadataBadge: View {
    let text: String
    let icon: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(tint.opacity(0.08))
        )
    }
}

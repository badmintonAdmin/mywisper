//
//  TranscribeFileView.swift
//  mywisper
//
//  Created by Сергей Борисов on 06.05.2026.
//

import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import AppKit

struct TranscribeFileView: View {
    @ObservedObject private var service = FileTranscriptionService.shared
    @ObservedObject private var settings = SettingsManager.shared

    /// Local state for the "user picked a file but hasn't started yet" UX.
    @State private var pickedFile: PickedFile?
    @State private var pickError: String?
    @State private var isHovering = false
    @State private var copyConfirmed = false

    struct PickedFile: Equatable {
        let url: URL
        let name: String
        let durationSeconds: TimeInterval
        let fileSizeMB: Double
        let isTooLong: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    switch service.state {
                    case .idle:
                        if let picked = pickedFile {
                            pickedFileCard(picked)
                        } else {
                            dropZone
                        }
                    case .preparing(let name):
                        progressCard(name: name, label: "Preparing audio…", progress: nil, elapsed: 0)
                    case .transcribing(let name, let progress, let elapsed):
                        progressCard(name: name, label: "Transcribing…", progress: progress, elapsed: elapsed)
                    case .done(let text, let url, let name, let total):
                        resultCard(text: text, sourceURL: url, sourceName: name, totalSeconds: total)
                    case .failed(let name, let message):
                        failureCard(sourceName: name, message: message)
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 600, minHeight: 480)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Transcribe File")
                    .font(.title)
                    .fontWeight(.bold)
                Text("Audio or video file → local Whisper transcription")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    // MARK: - Drop zone (State A)

    private var dropZone: some View {
        VStack(spacing: 14) {
            VStack(spacing: 12) {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 38, weight: .light))
                    .foregroundColor(.accentColor.opacity(isHovering ? 1.0 : 0.6))
                Text("Drop audio or video here")
                    .font(.system(size: 15, weight: .medium))
                Text("or click to browse")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text("WAV · MP3 · M4A · AAC · FLAC · AIFF · MP4 · MOV")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("max 60 minutes")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isHovering ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        isHovering ? Color.accentColor : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture { showOpenPanel() }
            .onDrop(of: [.fileURL], isTargeted: $isHovering) { providers in
                handleDrop(providers: providers)
            }

            if let pickError = pickError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 12))
                    Text(pickError)
                        .font(.system(size: 12))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.08))
                )
            }

            languagePicker
        }
    }

    // MARK: - Picked file (State B)

    private func pickedFileCard(_ picked: PickedFile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(picked.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(formatDuration(picked.durationSeconds)) · \(String(format: "%.1f MB", picked.fileSizeMB))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            if picked.isTooLong {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 12))
                    Text("Too long: \(formatDuration(picked.durationSeconds)) (max \(formatDuration(FileTranscriptionService.maxDurationSeconds))). Trim it and try again.")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red.opacity(0.08))
                )
            }

            languagePicker

            HStack(spacing: 8) {
                Button {
                    transcribePicked()
                } label: {
                    Label("Transcribe", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(picked.isTooLong)

                Button {
                    pickedFile = nil
                    pickError = nil
                } label: {
                    Text("Choose Different File")
                }
                .controlSize(.large)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Progress (State C)

    private func progressCard(name: String, label: String, progress: Double?, elapsed: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                if let progress = progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    HStack {
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(etaString(progress: progress, elapsed: elapsed))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }

            HStack {
                Spacer()
                Button(role: .destructive) {
                    service.cancel()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                }
                .controlSize(.regular)
            }

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text("You can close this window — the transcription continues in the background.")
                    .font(.system(size: 11))
            }
            .foregroundColor(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Result (State D)

    private func resultCard(text: String, sourceURL: URL, sourceName: String, totalSeconds: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sourceName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Transcribed in \(formatDuration(totalSeconds))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    copyResult(text)
                } label: {
                    Label(copyConfirmed ? "Copied!" : "Copy", systemImage: copyConfirmed ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.regular)

                Button {
                    saveResult(text: text, suggestedName: sourceURL.deletingPathExtension().lastPathComponent)
                } label: {
                    Label("Save as .txt…", systemImage: "square.and.arrow.down")
                }
                .controlSize(.regular)

                Spacer()

                Button {
                    service.clearLastResult()
                    pickedFile = nil
                    pickError = nil
                } label: {
                    Label("Transcribe Another", systemImage: "plus")
                }
                .controlSize(.regular)
            }

            Divider()

            ScrollView {
                Text(text.isEmpty ? "(empty result)" : text)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(minHeight: 220)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Failure

    private func failureCard(sourceName: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sourceName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Transcription failed")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red.opacity(0.08))
                )

            HStack {
                Button {
                    service.clearLastResult()
                    pickedFile = nil
                    pickError = nil
                } label: {
                    Label("Try Another File", systemImage: "arrow.clockwise")
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Reusable controls

    private var languagePicker: some View {
        HStack(spacing: 12) {
            Text("Language:")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Picker("Language", selection: $settings.selectedLanguage) {
                ForEach(DictationLanguage.all) { lang in
                    Text(lang.displayName).tag(lang.code)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 220)
            Spacer()
        }
    }

    // MARK: - Actions

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let urlValue = item as? URL {
                url = urlValue
            }
            guard let resolved = url else { return }
            Task { @MainActor in
                await pickFile(url: resolved)
            }
        }
        return true
    }

    private func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.audio, UTType.movie]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select an audio or video file (max 60 minutes)"
        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                await pickFile(url: url)
            }
        }
    }

    private func pickFile(url: URL) async {
        pickError = nil

        // Compute file size
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let sizeMB = Double(size) / (1024.0 * 1024.0)

        // Read duration via AVAsset
        let asset = AVURLAsset(url: url)
        let duration: TimeInterval
        do {
            let cmTime = try await asset.load(.duration)
            duration = CMTimeGetSeconds(cmTime)
            guard duration.isFinite, duration > 0 else {
                pickError = "Couldn't read duration. Is this an audio or video file?"
                return
            }
        } catch {
            pickError = "Couldn't read this file: \(error.localizedDescription)"
            return
        }

        pickedFile = PickedFile(
            url: url,
            name: url.lastPathComponent,
            durationSeconds: duration,
            fileSizeMB: sizeMB,
            isTooLong: duration > FileTranscriptionService.maxDurationSeconds
        )
    }

    private func transcribePicked() {
        guard let picked = pickedFile, !picked.isTooLong else { return }
        let url = picked.url
        let lang = settings.selectedLanguage
        pickedFile = nil
        Task { @MainActor in
            let result = await service.start(sourceURL: url, language: lang)
            if case .failure(let err) = result {
                pickError = err.localizedDescription
                pickedFile = picked  // restore so user can retry
            }
        }
    }

    private func copyResult(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyConfirmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copyConfirmed = false
        }
    }

    private func saveResult(text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.plainText]
        panel.nameFieldStringValue = "\(suggestedName).txt"
        panel.message = "Save transcription"
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func etaString(progress: Double, elapsed: TimeInterval) -> String {
        guard progress > 0.01, elapsed > 0 else {
            return "\(Int(elapsed))s elapsed"
        }
        let total = elapsed / progress
        let remaining = max(0, total - elapsed)
        return "~\(formatDuration(remaining)) remaining"
    }
}

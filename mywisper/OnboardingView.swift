//
//  OnboardingView.swift
//  mywisper
//
//  First-run setup checklist: walks the user through the three things mywisper
//  needs to work — microphone access, Accessibility (global hotkeys + auto-paste),
//  and choosing a transcription engine. Shown automatically on first launch and
//  re-openable from Settings ("Open Setup Guide"). Each step shows live granted/
//  not-granted status with an action button.
//

import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @ObservedObject var settings = SettingsManager.shared

    /// Called when the user finishes (or skips) onboarding so the host window can close.
    var onFinish: () -> Void = {}

    // Live permission state. Polled on a timer because permission grants happen in
    // System Settings, out of our process, so there's no callback to observe.
    @State private var micStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibilityGranted: Bool = TextPaster.checkAccessibilityPermission()

    private let pollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var micGranted: Bool { micStatus == .authorized }

    private var engineChosen: Bool {
        switch settings.engine {
        case .apple:
            return true
        case .whisper:
            return !settings.whisperModelPath.isEmpty
                && FileManager.default.fileExists(atPath: settings.whisperModelPath)
        case .cloud:
            return !settings.openAIKey.isEmpty
        }
    }

    private var allReady: Bool { micGranted && accessibilityGranted && engineChosen }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to My Whisper")
                        .font(.system(size: 20, weight: .bold))
                    Text("Three quick steps and you're ready to dictate.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    microphoneStep
                    accessibilityStep
                    engineStep
                }
                .padding(16)
            }

            Divider()

            // Footer
            HStack {
                if allReady {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("All set!")
                            .font(.system(size: 12, weight: .medium))
                    }
                } else {
                    Text("You can finish setup later from Settings.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(allReady ? "Done" : "Skip for now") {
                    settings.hasCompletedOnboarding = true
                    onFinish()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
        .onReceive(pollTimer) { _ in
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            accessibilityGranted = TextPaster.checkAccessibilityPermission()
        }
    }

    // MARK: - Step 1: Microphone

    private var microphoneStep: some View {
        StepCard(
            number: 1,
            title: "Microphone",
            subtitle: "Required to record your speech",
            isDone: micGranted
        ) {
            if micGranted {
                StatusPill(text: "Granted", icon: "checkmark.circle.fill", isGood: true)
            } else {
                StatusPill(text: "Not granted", icon: "xmark.circle.fill", isGood: false)
                HStack(spacing: 8) {
                    if micStatus == .notDetermined {
                        Button {
                            AVCaptureDevice.requestAccess(for: .audio) { granted in
                                DispatchQueue.main.async {
                                    micStatus = granted ? .authorized : .denied
                                }
                            }
                        } label: {
                            Label("Allow Microphone", systemImage: "mic")
                        }
                        .controlSize(.small)
                    } else {
                        Button {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        } label: {
                            Label("Open System Settings", systemImage: "gear")
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Step 2: Accessibility

    private var accessibilityStep: some View {
        StepCard(
            number: 2,
            title: "Accessibility",
            subtitle: "Needed for global hotkeys & auto-paste",
            isDone: accessibilityGranted
        ) {
            if accessibilityGranted {
                StatusPill(text: "Granted", icon: "checkmark.circle.fill", isGood: true)
            } else {
                StatusPill(text: "Not granted", icon: "xmark.circle.fill", isGood: false)
                Text("Without it, recording still works from the menu bar, but global hotkeys and automatic pasting won't.")
                    .font(.system(size: 11))
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

    // MARK: - Step 3: Engine

    private var engineStep: some View {
        StepCard(
            number: 3,
            title: "Transcription Engine",
            subtitle: "Choose how speech becomes text",
            isDone: engineChosen
        ) {
            Picker("Engine", selection: $settings.engine) {
                ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            switch settings.engine {
            case .apple:
                StatusPill(text: "Ready to use", icon: "checkmark.circle.fill", isGood: true)
            case .whisper:
                if engineChosen {
                    let name = URL(fileURLWithPath: settings.whisperModelPath).lastPathComponent
                    StatusPill(text: "Model: \(name)", icon: "checkmark.circle.fill", isGood: true)
                } else {
                    StatusPill(text: "No model selected", icon: "exclamationmark.triangle.fill", isGood: false)
                    Text("Pick or download a model in Settings → General.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Button {
                        NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
                    } label: {
                        Label("Open Settings", systemImage: "gear")
                    }
                    .controlSize(.small)
                }
            case .cloud:
                if engineChosen {
                    StatusPill(text: "API key configured", icon: "checkmark.circle.fill", isGood: true)
                } else {
                    StatusPill(text: "API key required", icon: "exclamationmark.triangle.fill", isGood: false)
                    Text("Add your OpenAI API key in Settings → AI Processing.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Button {
                        NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
                    } label: {
                        Label("Open Settings", systemImage: "gear")
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Step Card

private struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let subtitle: String
    let isDone: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isDone ? Color.green : Color.accentColor.opacity(0.15))
                        .frame(width: 26, height: 26)
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Text("\(number)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.accentColor)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(.leading, 36)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isDone ? Color.green.opacity(0.3) : Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }
}

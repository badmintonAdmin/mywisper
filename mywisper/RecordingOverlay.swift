//
//  RecordingOverlay.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import SwiftUI
import AppKit

class OverlayState: ObservableObject {
    @Published var statusText: String = "Recording..."
    @Published var audioLevel: Float = 0.0
    @Published var isRecording: Bool = false
    @Published var isTranscribing: Bool = false
    @Published var elapsedSeconds: TimeInterval = 0
    /// Determinate transcription progress (0...1). nil → show an indeterminate indicator
    /// (e.g. AI processing or a cloud upload where no real percentage is available).
    @Published var progress: Double? = nil
    var onStop: (() -> Void)?
    /// Triggered by the visible cancel affordance during transcribing — wired to
    /// DictationManager.cancelOperation().
    var onCancel: (() -> Void)?
}

class RecordingPanel: NSPanel {
    let state = OverlayState()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false // We draw our own glow
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Draggable: let the user move the pill anywhere and remember where they left it.
        self.isMovableByWindowBackground = true
        self.isMovable = true
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.ignoresMouseEvents = false // Allow stop button clicks
        self.hidesOnDeactivate = false
        self.animationBehavior = .none

        let hostingView = NSHostingView(rootView: RecordingOverlayView(state: state))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        self.contentView = hostingView

        positionFromDefaultsOrCenter()
    }

    /// UserDefaults keys for the persisted (user-dragged) panel origin.
    private static let originXKey = "overlayOriginX"
    private static let originYKey = "overlayOriginY"

    /// The centered default origin (top-center of the main screen) used on first run.
    private func defaultCenteredOrigin() -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: 0, y: 0) }
        let x = (screen.frame.width - 220) / 2
        let y = screen.frame.height - 90
        return NSPoint(x: x, y: y)
    }

    /// Restore the user's last dragged position; fall back to the centered default if none saved.
    private func positionFromDefaultsOrCenter() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.originXKey) != nil,
           defaults.object(forKey: Self.originYKey) != nil {
            let x = defaults.double(forKey: Self.originXKey)
            let y = defaults.double(forKey: Self.originYKey)
            self.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            self.setFrameOrigin(defaultCenteredOrigin())
        }
    }

    /// Persist the current origin whenever the user finishes dragging the panel.
    private func saveOrigin() {
        let origin = self.frame.origin
        UserDefaults.standard.set(Double(origin.x), forKey: Self.originXKey)
        UserDefaults.standard.set(Double(origin.y), forKey: Self.originYKey)
    }

    // Persist the panel's position after the user finishes dragging it (mouse-up ends an
    // isMovableByWindowBackground drag); next show() reuses it instead of re-centering.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        saveOrigin()
    }

    func show() {
        // Reuse the user's last position (or the default) — do NOT force re-center every time.
        positionFromDefaultsOrCenter()
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}

struct RecordingOverlayView: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        HStack(spacing: 0) {
            // Left: red dot indicator
            ZStack {
                if state.isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                        .shadow(color: .red.opacity(0.8), radius: 4)
                } else if state.isTranscribing {
                    TranscribingDotsView()
                        .frame(width: 24, height: 14)
                }
            }
            .frame(width: 24)
            .padding(.leading, 10)

            // Center: waveform + text + timer
            HStack(spacing: 6) {
                if state.isRecording {
                    AudioWaveformView(level: CGFloat(state.audioLevel))
                        .frame(width: 30, height: 16)
                }

                Text(state.statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)

                if state.isRecording {
                    RecordingTimerView(elapsed: state.elapsedSeconds)
                }

                // Real percentage for long local-Whisper runs; AI/cloud stay indeterminate.
                if state.isTranscribing, let progress = state.progress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity)

            // Right: stop button (recording) / cancel affordance (transcribing)
            if state.isRecording {
                Button {
                    state.onStop?()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 24, height: 24)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.red)
                            .frame(width: 9, height: 9)
                    }
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
            } else if state.isTranscribing {
                Button {
                    state.onCancel?()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                        Text("Esc")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.white.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
                .help("Cancel (Esc)")
                .padding(.trailing, 10)
            } else {
                Spacer().frame(width: 10)
            }
        }
        .frame(minWidth: 180, minHeight: 32)
        .padding(.vertical, 5)
        .background(
            ZStack {
                // Main pill background
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(white: 0.1).opacity(0.92))

                // Subtle border
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            }
        )
        .fixedSize()
    }
}

// MARK: - Recording Timer

struct RecordingTimerView: View {
    let elapsed: TimeInterval

    var body: some View {
        Text(formatTime(elapsed))
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundColor(.white.opacity(0.4))
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let mins = Int(interval) / 60
        let secs = Int(interval) % 60
        let tenths = Int((interval - Double(Int(interval))) * 10)
        if mins > 0 {
            return String(format: "%d:%02d.%d", mins, secs, tenths)
        }
        return String(format: "%d.%ds", secs, tenths)
    }
}

// MARK: - Transcribing Animation

struct TranscribingDotsView: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.white)
                    .frame(width: 5, height: 5)
                    .scaleEffect(dotScale(for: index))
                    .opacity(dotOpacity(for: index))
                    .animation(.easeInOut(duration: 0.25), value: phase)
            }
        }
        .onReceive(timer) { _ in
            phase = (phase + 1) % 6
        }
    }

    private func dotScale(for index: Int) -> CGFloat {
        let active = phase % 3
        if index == active { return 1.5 }
        let dist = min(abs(index - active), 3 - abs(index - active))
        if dist == 1 { return 1.1 }
        return 0.7
    }

    private func dotOpacity(for index: Int) -> Double {
        let active = phase % 3
        if index == active { return 1.0 }
        let dist = min(abs(index - active), 3 - abs(index - active))
        if dist == 1 { return 0.6 }
        return 0.3
    }
}

// MARK: - Audio Waveform

struct AudioWaveformView: View {
    let level: CGFloat
    private let barCount = 5

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { index in
                AudioBar(level: level, index: index, total: barCount)
            }
        }
    }
}

struct AudioBar: View {
    let level: CGFloat
    let index: Int
    let total: Int

    private var barHeight: CGFloat {
        let center = CGFloat(total) / 2.0
        let distFromCenter = abs(CGFloat(index) - center) / center
        let scale = 1.0 - distFromCenter * 0.35
        let minHeight: CGFloat = 4
        let maxHeight: CGFloat = 20
        let offset = sin(Double(index) * 1.3) * 0.15
        let effectiveLevel = min(1, max(0, level * scale + CGFloat(offset) * level))
        return minHeight + (maxHeight - minHeight) * effectiveLevel
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.white.opacity(0.7))
            .frame(width: 3, height: barHeight)
            .animation(.easeOut(duration: 0.08), value: level)
    }
}

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
    var onStop: (() -> Void)?
}

class RecordingPanel: NSPanel {
    let state = OverlayState()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 70),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false // We draw our own glow
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isMovableByWindowBackground = false
        self.isMovable = false
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.ignoresMouseEvents = false // Allow stop button clicks
        self.hidesOnDeactivate = false
        self.animationBehavior = .none

        let hostingView = NSHostingView(rootView: RecordingOverlayView(state: state))
        self.contentView = hostingView

        centerOnScreen()
    }

    private func centerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let x = (screen.frame.width - 300) / 2
        let y = screen.frame.height - 110
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func show() {
        centerOnScreen()
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
                    // Pulsing red dot
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .shadow(color: .red.opacity(0.8), radius: 6)
                } else if state.isTranscribing {
                    TranscribingDotsView()
                        .frame(width: 32, height: 20)
                }
            }
            .frame(width: 32)
            .padding(.leading, 14)

            // Center: waveform + text + timer
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    if state.isRecording {
                        AudioWaveformView(level: CGFloat(state.audioLevel))
                            .frame(width: 40, height: 22)
                    }

                    Text(state.statusText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }

                if state.isRecording {
                    RecordingTimerView(elapsed: state.elapsedSeconds)
                }
            }
            .frame(maxWidth: .infinity)

            // Right: stop button
            if state.isRecording {
                Button {
                    state.onStop?()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 32, height: 32)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.red)
                            .frame(width: 12, height: 12)
                    }
                }
                .buttonStyle(.plain)
                .padding(.trailing, 14)
            } else {
                Spacer().frame(width: 14)
            }
        }
        .frame(minWidth: 260, minHeight: 48)
        .padding(.vertical, 8)
        .background(
            ZStack {
                // Red glow underneath
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.red.opacity(state.isRecording ? 0.15 : 0))
                    .blur(radius: 12)
                    .offset(y: 4)

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
            .fill(Color.red)
            .frame(width: 3, height: barHeight)
            .animation(.easeOut(duration: 0.08), value: level)
    }
}

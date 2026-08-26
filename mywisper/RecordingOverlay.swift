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
    /// True while the current recording is using the live (segmented) path. Drives the slow pulse
    /// on the red dot so the user can tell at a glance that on-the-fly transcription is active.
    @Published var isLiveSession: Bool = false
    /// Number of audio segments already transcribed on the fly during the current live recording.
    /// Shown as a small "⚡N" badge so the user can SEE chunks being processed while still speaking.
    @Published var liveSegmentsDone: Int = 0
    @Published var elapsedSeconds: TimeInterval = 0
    /// Determinate transcription progress (0...1). nil → show an indeterminate indicator
    /// (e.g. AI processing or a cloud upload where no real percentage is available).
    @Published var progress: Double? = nil
    /// Island mode: drives the slide-down reveal / retract animation. Set by the panel
    /// after ordering front (true) and just before ordering out (false).
    @Published var islandRevealed: Bool = false
    /// Raw recent mic levels, newest last, one per waveform bar — the shared feed for every
    /// island waveform style. Lightly EMA-smoothed at the writer (DictationManager).
    @Published var levelHistory: [Float] = [Float](repeating: 0, count: OverlayState.levelHistoryCount)
    /// False once levels stop arriving while recording: a dead microphone must look
    /// different from silence (Talkify's CONTEXT rule) — the visuals turn amber.
    @Published var isAudioAlive: Bool = true
    /// Bumped once per recording start; one-shot effects (glow bloom, ripple, sweep phase)
    /// trigger on the change so they never re-fire mid-session.
    @Published var sessionEpoch: Int = 0
    /// The live draft while recording — what's been recognized so far, streaming in from
    /// the fast engines. Empty when the active engine can't stream text (batch Whisper).
    /// Drives the island's Compact visual.
    @Published var liveText: String = ""
    static let levelHistoryCount = 56
    var onStop: (() -> Void)?
    /// Triggered by the visible cancel affordance during transcribing — wired to
    /// DictationManager.cancelOperation().
    var onCancel: (() -> Void)?
}

/// Measured notch geometry, adapted from Talkify's HUDNotchGeometry (itself after Tilebar's
/// NotchIsland pattern). Decides what the display imposes: the housing footprint the island
/// descends from, whether concave fillets exist, and the clearance below the menu bar on
/// displays with no notch. The island's CONTENT always starts below the housing band, so
/// nothing ever collides with the camera.
enum NotchGeometry {
    /// Stand-in footprint for a display that reports no notch. The menu-bar height is not a
    /// usable substitute — auto-hidden it measures zero, collapsing the housing to nothing.
    static let fallbackClosedSize = CGSize(width: 185, height: 32)

    /// Slack around the shape so its drawn shadow AND the Edge Glow's blurred strokes
    /// (spill 24 + blur ~12) aren't clipped by the panel frame — Talkify uses 44 for the
    /// same reason. Nothing is added at the top: that edge is the top of the screen and
    /// the shape is flush against it.
    static let shadowPadding: CGFloat = 48

    /// The notch this display actually reports, or nil when there is nothing to measure.
    /// Width comes from the two auxiliary areas by subtraction so the result doesn't depend
    /// on which coordinate space they arrive in.
    static func measuredClosedSize(for screen: NSScreen) -> CGSize? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              screen.safeAreaInsets.top > 0
        else { return nil }
        let width = screen.frame.width - left.width - right.width
        guard width > 0, width < screen.frame.width else { return nil }
        return CGSize(width: width, height: screen.safeAreaInsets.top)
    }

    /// The housing footprint, falling back to the simulated stand-in.
    static func closedSize(for screen: NSScreen) -> CGSize {
        measuredClosedSize(for: screen) ?? fallbackClosedSize
    }

    static func hasNotch(_ screen: NSScreen) -> Bool {
        measuredClosedSize(for: screen) != nil
    }

    /// Concave corner flaring the shape into the bezel; zero without a housing to flare into.
    static func filletSize(for screen: NSScreen) -> CGFloat {
        hasNotch(screen) ? 11 : 0
    }

    /// A real notch sits in its own housing, clear of status items. The simulated stand-in
    /// would draw straight over the menu bar, so there the shape hangs just below it.
    static func topInset(for screen: NSScreen) -> CGFloat {
        hasNotch(screen) ? 0 : max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// The island must read as the notch growing, so it's never narrower than the housing
    /// plus its fillets and a small shoulder each side.
    static func islandWidth(for screen: NSScreen) -> CGFloat {
        let closed = closedSize(for: screen)
        return max(closed.width + filletSize(for: screen) * 2 + 8, 400)
    }

    /// The tallest content band (the waveform visual's) — the panel window is sized for
    /// this whatever the current state, so it never resizes; smaller bands top-align inside.
    static let bandHeight: CGFloat = 56

    /// Height of the island's band for a given visual while recording; status/transcribing
    /// bands use the compact height.
    static func visualBandHeight(for visual: IslandVoiceVisual) -> CGFloat {
        switch visual {
        case .waveform: return 56
        case .glow: return 44
        case .compact: return 40
        case .minimal: return 40
        }
    }

    static let statusBandHeight: CGFloat = 40
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
    // Island mode is fixed at the notch — never let its frame overwrite the pill's spot.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if SettingsManager.shared.overlayStyle == .classic {
            saveOrigin()
        }
    }

    /// Invalidates a pending retract-then-orderOut when a newer show() supersedes it.
    private var hideToken = 0

    func show() {
        hideToken += 1
        if SettingsManager.shared.overlayStyle == .island {
            // Island mode: docked flush against the top of the screen (visually extending
            // the notch); not draggable — the whole point is that it lives at the notch.
            isMovableByWindowBackground = false
            isMovable = false
            applyIslandFrame()
            orderFrontRegardless()
            // Reveal on the next runloop tick so SwiftUI animates from the parked state.
            if !state.islandRevealed {
                DispatchQueue.main.async { [weak self] in self?.state.islandRevealed = true }
            }
        } else {
            state.islandRevealed = false
            isMovableByWindowBackground = true
            isMovable = true
            setContentSize(NSSize(width: 220, height: 44))
            // Reuse the user's last position (or the default) — do NOT force re-center every time.
            positionFromDefaultsOrCenter()
            orderFrontRegardless()
        }
    }

    /// Size and dock the panel at the top center of the main screen, flush with the top edge
    /// (or just under the menu bar on displays without a notch). Sized from the measured
    /// housing plus shadow slack; the shape top-aligns inside and centers itself.
    private func applyIslandFrame() {
        guard let screen = NSScreen.main else { return }
        let width = NotchGeometry.islandWidth(for: screen) + NotchGeometry.shadowPadding * 2
        let height = NotchGeometry.closedSize(for: screen).height
            + NotchGeometry.bandHeight
            + NotchGeometry.shadowPadding
        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - height - NotchGeometry.topInset(for: screen)
        setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    func hide() {
        if SettingsManager.shared.overlayStyle == .island, state.islandRevealed {
            // Retract first (slide back up into the housing), then order out.
            state.islandRevealed = false
            hideToken += 1
            let token = hideToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                guard let self = self, self.hideToken == token else { return }
                self.orderOut(nil)
            }
        } else {
            state.islandRevealed = false
            orderOut(nil)
        }
    }
}

struct RecordingOverlayView: View {
    @ObservedObject var state: OverlayState
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        if settings.overlayStyle == .island {
            IslandOverlayView(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            classicPill
        }
    }

    private var classicPill: some View {
        HStack(spacing: 0) {
            // Left: red dot indicator
            ZStack {
                if state.isRecording {
                    RecordingDot(isLive: state.isLiveSession)
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

                // Live proof: how many segments have already been transcribed on the fly.
                if state.isRecording, state.isLiveSession, state.liveSegmentsDone > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold))
                        Text("\(state.liveSegmentsDone)").font(.system(size: 10, weight: .semibold, design: .monospaced))
                    }
                    .foregroundColor(.green)
                    .help("\(state.liveSegmentsDone) part(s) already transcribed live")
                    .padding(.leading, 4)
                }

                // Real percentage for long local-Whisper runs; AI/cloud stay indeterminate.
                if state.isTranscribing, let progress = state.progress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.trailing, 8)

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

// MARK: - Recording Dot

/// The red recording indicator. Static in the classic path; a slow, gentle pulse when live
/// (segmented) transcription is running, as a quiet "working on the fly" cue.
struct RecordingDot: View {
    let isLive: Bool
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 7, height: 7)
            .shadow(color: .red.opacity(0.8), radius: 4)
            .scaleEffect(isLive && pulsing ? 1.5 : 1.0)
            .opacity(isLive && pulsing ? 0.5 : 1.0)
            .animation(
                isLive ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default,
                value: pulsing
            )
            .onAppear { if isLive { pulsing = true } }
            .onChange(of: isLive) { pulsing = $0 }
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

// MARK: - Notch Island (after Talkify's HUD)

/// A black shape descending from the notch housing, after Talkify's dictation HUD: the top
/// band is exactly the housing's footprint and stays EMPTY (its pixels sit behind the camera
/// on a notched display), content lives in the band below, concave fillets flare the top
/// corners into the bezel. The voice visual, its style, the Edge Glow palette/particles, the
/// reveal animation, and our own chrome (dot / timer / stop) are all Settings picks.
struct IslandOverlayView: View {
    @ObservedObject var state: OverlayState
    @ObservedObject private var settings = SettingsManager.shared

    /// Reset per session for the one-shot ripple across the housing (glow visual only).
    @State private var rippleStart = Date.distantPast

    /// Geometry snapshot of the screen the panel is docked on.
    private var screen: NSScreen? { NSScreen.main }
    private var closedSize: CGSize {
        screen.map { NotchGeometry.closedSize(for: $0) } ?? NotchGeometry.fallbackClosedSize
    }
    private var islandWidth: CGFloat {
        screen.map { NotchGeometry.islandWidth(for: $0) } ?? 400
    }
    private var filletSize: CGFloat {
        screen.map { NotchGeometry.filletSize(for: $0) } ?? 0
    }

    /// The band is sized by what it currently shows; the panel window is sized for the
    /// tallest case, so the shape just top-aligns inside it (Talkify's fixed-window rule).
    private var bandHeight: CGFloat {
        state.isRecording
            ? NotchGeometry.visualBandHeight(for: settings.islandVisual)
            : NotchGeometry.statusBandHeight
    }
    private var totalHeight: CGFloat { closedSize.height + bandHeight }
    private var bottomCornerRadius: CGFloat { 20 }

    private var housingShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            bottomLeadingRadius: bottomCornerRadius,
            bottomTrailingRadius: bottomCornerRadius,
            style: .continuous
        )
    }

    private var showsGlow: Bool { settings.islandVisual == .glow && state.isRecording }

    var body: some View {
        VStack(spacing: 0) {
            // Housing band: kept empty so content never collides with the camera. On a
            // notched display these pixels are literally behind hardware.
            Color.clear
                .frame(height: closedSize.height)

            contentBand
                .frame(height: bandHeight, alignment: .center)
        }
        .frame(width: islandWidth)
        .background(housing)
        .overlay {
            // Particle cloud, clipped to the housing so no mote leaks past the silhouette.
            if showsGlow, settings.islandGlowParticles {
                IslandParticleCloudView(
                    state: state,
                    palette: settings.islandGlowPalette,
                    cornerRadius: bottomCornerRadius,
                    topFilletRadius: filletSize
                )
                .clipShape(housingShape)
            }
        }
        .overlay {
            // The Edge Glow beam blooming along the open silhouette.
            if settings.islandVisual == .glow, state.isRecording {
                IslandEdgeGlowView(
                    state: state,
                    palette: settings.islandGlowPalette,
                    cornerRadius: bottomCornerRadius,
                    topFilletRadius: filletSize
                )
            }
        }
        .overlay(alignment: .topLeading) { fillet(isLeading: true) }
        .overlay(alignment: .topTrailing) { fillet(isLeading: false) }
        .opacity(revealOpacity)
        .scaleEffect(x: revealScale.x, y: revealScale.y, anchor: .top)
        .offset(y: revealOffset)
        .animation(revealAnimation, value: state.islandRevealed)
        .animation(.spring(duration: 0.25, bounce: 0), value: bandHeight)
        .onChange(of: state.sessionEpoch) { _ in
            rippleStart = Date()
        }
    }

    /// The black shape. With the glow visual, the one-shot ripple (Ripple.metal) displaces
    /// its pixels once at session start; the shadow stays outside the effect so it doesn't
    /// shimmer with the wave.
    @ViewBuilder
    private var housing: some View {
        Group {
            if #available(macOS 14.0, *), settings.islandVisual == .glow {
                TimelineView(.animation(paused: !state.isRecording)) { context in
                    Color.black
                        .clipShape(housingShape)
                        .modifier(IslandRippleModifier(
                            origin: CGPoint(x: islandWidth / 2, y: closedSize.height),
                            elapsedTime: context.date.timeIntervalSince(rippleStart),
                            isEnabled: true
                        ))
                }
            } else {
                Color.black.clipShape(housingShape)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 11, y: 4)
    }

    // MARK: Reveal (Talkify's HUDSurface styles)

    /// Where position moves at all, hidden means at or above the window's top edge — never
    /// below — so no style can open a gap against the screen edge.
    private var revealOffset: CGFloat {
        guard !state.islandRevealed else { return 0 }
        switch settings.islandRevealStyle {
        case .slide: return -(totalHeight + 20)
        case .unfurl, .bloom: return 0
        case .drift: return -14
        }
    }

    /// Bounce lives only in top-anchored scale (unfurl, bloom); the styles that move
    /// position stay bounce-free, or overshoot would detach the shape from the edge.
    private var revealScale: (x: CGFloat, y: CGFloat) {
        guard !state.islandRevealed else { return (1, 1) }
        switch settings.islandRevealStyle {
        case .slide, .drift: return (1, 1)
        case .unfurl: return (1, 0.001)
        case .bloom: return (0.55, 0.55)
        }
    }

    private var revealOpacity: Double {
        switch settings.islandRevealStyle {
        case .slide, .unfurl: return 1
        case .bloom, .drift: return state.islandRevealed ? 1 : 0
        }
    }

    private var revealAnimation: Animation {
        if state.islandRevealed {
            switch settings.islandRevealStyle {
            case .slide: return .spring(duration: 0.4, bounce: 0)
            case .unfurl: return .spring(duration: 0.45, bounce: 0.3)
            case .bloom: return .spring(duration: 0.4, bounce: 0.25)
            case .drift: return .easeOut(duration: 0.24)
            }
        }
        switch settings.islandRevealStyle {
        case .slide, .unfurl, .bloom: return .spring(duration: 0.28, bounce: 0)
        case .drift: return .easeIn(duration: 0.18)
        }
    }

    @ViewBuilder
    private var contentBand: some View {
        if state.isRecording {
            HStack(spacing: 10) {
                if settings.islandShowRecordingDot {
                    RecordingDot(isLive: state.isLiveSession)
                        .frame(width: 16)
                }

                // The visual fills whatever room the chrome leaves. Edge Glow keeps the
                // band as an empty stage — its beam and particles are shape-wide overlays.
                Group {
                    switch settings.islandVisual {
                    case .waveform:
                        IslandWaveformBand(state: state, style: settings.islandWaveformStyle)
                    case .glow:
                        Color.clear
                    case .compact:
                        IslandCompactBand(state: state)
                    case .minimal:
                        IslandLevelMeter(state: state)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if state.isLiveSession, state.liveSegmentsDone > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold))
                        Text("\(state.liveSegmentsDone)").font(.system(size: 10, weight: .semibold, design: .monospaced))
                    }
                    .foregroundColor(.green)
                }

                if settings.islandShowTimer {
                    RecordingTimerView(elapsed: state.elapsedSeconds)
                }

                if settings.islandShowStopButton {
                    Button {
                        state.onStop?()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.12))
                                .frame(width: 22, height: 22)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        } else if state.isTranscribing {
            HStack(spacing: 10) {
                TranscribingDotsView()
                    .frame(width: 24, height: 14)

                Text(state.statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let progress = state.progress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                }

                Button {
                    state.onCancel?()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        Text("Esc").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        } else {
            // Transient notice ("No speech detected", "Copied to clipboard…")
            Text(state.statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
    }

    /// The concave corner joining the island's flank to the top edge of the screen. Only on
    /// displays with a real housing — without one the flare reads as detached tabs.
    @ViewBuilder
    private func fillet(isLeading: Bool) -> some View {
        if filletSize > 0 {
            Color.black
                .frame(width: filletSize, height: filletSize)
                .clipShape(NotchFilletShape(isLeading: isLeading))
                .offset(x: isLeading ? -filletSize : filletSize)
        }
    }
}

/// A square with a concave quarter-arc removed from its *outer* bottom corner — the corner
/// furthest from the island body. The black stays full height where it meets the flank and
/// tapers out along the screen's top edge, which is what reads as the housing flaring wider.
/// (Drawn with an explicit Bézier quarter-arc: Path booleans need macOS 14, we target 13.3.)
struct NotchFilletShape: Shape {
    let isLeading: Bool

    func path(in rect: CGRect) -> Path {
        // Magic constant for a cubic Bézier quarter-circle.
        let k: CGFloat = 0.5522847498
        let r = min(rect.width, rect.height)
        var p = Path()
        if isLeading {
            // Disc center at (minX, maxY): arc runs (maxX, maxY) → (minX, minY).
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addCurve(
                to: CGPoint(x: rect.minX, y: rect.minY),
                control1: CGPoint(x: rect.minX + r, y: rect.maxY - k * r),
                control2: CGPoint(x: rect.minX + k * r, y: rect.maxY - r)
            )
        } else {
            // Mirrored: disc center at (maxX, maxY).
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY),
                control1: CGPoint(x: rect.maxX - r, y: rect.maxY - k * r),
                control2: CGPoint(x: rect.maxX - k * r, y: rect.maxY - r)
            )
        }
        p.closeSubpath()
        return p
    }
}


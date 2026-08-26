//
//  IslandSettingsView.swift
//  mywisper
//
//  The island's visual settings, shown as previews rather than words: a live
//  mini-island at the top rendering the real thing against a wallpaper-like
//  backdrop, one animated thumbnail per waveform style, gradient swatches for
//  the glow palettes, and reveal-animation cards that replay the animation in
//  the live preview when picked. Driven by synthesized speech-like levels
//  (after Talkify's HUDPreviews harness), so everything moves the way it will
//  in a real dictation.
//

import SwiftUI

// MARK: - Synthesized speech driver

/// Feeds a standalone OverlayState with speech-like levels at ~30 Hz: bursts
/// of talking separated by short pauses, run through the same fast-attack /
/// slow-release and EMA smoothing the real mic path uses.
final class IslandPreviewDriver: ObservableObject {
    let state = OverlayState()
    private var timer: Timer?
    private var t: Double = 0
    private var speaking = true
    private var phaseEnd: Double = 1.4

    func start() {
        guard timer == nil else { return }
        state.isRecording = true
        state.isAudioAlive = true
        state.sessionEpoch += 1
        state.islandRevealed = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Retract the mini-island and reveal it again — how a reveal pick shows itself.
    func replayReveal() {
        state.islandRevealed = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.state.sessionEpoch += 1
            self.state.islandRevealed = true
        }
    }

    /// Restart the one-shot session effects (glow bloom, ripple) without a retract.
    func replaySession() {
        state.sessionEpoch += 1
    }

    /// Feeds the Compact visual's live-draft preview one word at a time.
    private static let sampleWords = "This is what your dictation looks like while you speak — the newest words stay visible on the right".split(separator: " ").map(String.init)
    private var wordIndex = 0
    private var nextWordAt: Double = 0.4

    private func tick() {
        t += 1.0 / 30.0
        if t > phaseEnd {
            speaking.toggle()
            phaseEnd = t + (speaking ? Double.random(in: 1.0...2.2) : Double.random(in: 0.3...0.8))
        }
        let raw: Float
        if speaking {
            let s = abs(sin(t * 9)) * 0.7 + abs(sin(t * 23)) * 0.3
            raw = Float(min(1, max(0, s * Double.random(in: 0.55...1.0))))
            if t > nextWordAt {
                nextWordAt = t + Double.random(in: 0.25...0.45)
                let word = Self.sampleWords[wordIndex % Self.sampleWords.count]
                wordIndex += 1
                if wordIndex % Self.sampleWords.count == 0 {
                    state.liveText = word
                } else {
                    state.liveText = state.liveText.isEmpty ? word : state.liveText + " " + word
                }
            }
        } else {
            raw = Float(Double.random(in: 0...0.04))
        }
        state.audioLevel = max(raw, state.audioLevel * 0.88)
        state.levelHistory.removeFirst()
        let last = state.levelHistory.last ?? 0
        state.levelHistory.append(0.6 * raw + 0.4 * last)
        state.elapsedSeconds += 1.0 / 30.0
    }
}

// MARK: - Settings section

/// Everything the island lets you pick, previewed live. Dropped into the
/// Recording Indicator card when the island style is selected.
struct IslandSettingsSection: View {
    @ObservedObject private var settings = SettingsManager.shared
    @StateObject private var driver = IslandPreviewDriver()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            livePreview

            // Visual family
            HStack(spacing: 8) {
                ForEach(IslandVoiceVisual.allCases, id: \.self) { visual in
                    visualCard(visual)
                }
            }

            if settings.islandVisual == .waveform {
                waveformStyleGrid
            }

            if settings.islandVisual == .glow {
                paletteRow
                HStack {
                    elementChip("Particle cloud", icon: "sparkles", isOn: $settings.islandGlowParticles)
                    Spacer()
                }
                .onChange(of: settings.islandGlowParticles) { _ in driver.replaySession() }
            }

            revealRow

            Divider().padding(.vertical, 2)

            elementsRow
        }
        .onAppear { driver.start() }
        .onDisappear { driver.stop() }
    }

    // MARK: Live preview

    /// The real island view, scaled down, over a wallpaper-like gradient — what you pick
    /// below is what moves here.
    private var livePreview: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.16, blue: 0.38),
                    Color(red: 0.45, green: 0.2, blue: 0.5),
                    Color(red: 0.85, green: 0.45, blue: 0.35),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            IslandOverlayView(state: driver.state)
                .scaleEffect(0.68, anchor: .top)
        }
        .frame(height: 86)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) {
            Button {
                driver.replayReveal()
            } label: {
                Label("Replay", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.35)))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .padding(6)
            .help("Replay the appear animation")
        }
    }

    // MARK: Visual family cards

    private func visualCard(_ visual: IslandVoiceVisual) -> some View {
        let selected = settings.islandVisual == visual
        return Button {
            settings.islandVisual = visual
            driver.replaySession()
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.black)
                    switch visual {
                    case .waveform:
                        IslandWaveformBand(state: driver.state, style: settings.islandWaveformStyle)
                            .padding(.horizontal, 2)
                    case .glow:
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(settings.islandGlowPalette.stroke, lineWidth: 2.5)
                            .padding(3)
                            .blur(radius: 0.5)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(settings.islandGlowPalette.stroke, lineWidth: 4)
                                    .padding(3)
                                    .blur(radius: 6)
                                    .opacity(0.4 + 0.6 * Double(driver.state.audioLevel))
                            )
                    case .compact:
                        HStack(spacing: 6) {
                            IslandCompactIndicator(state: driver.state)
                            VStack(alignment: .leading, spacing: 2) {
                                Capsule().fill(.white.opacity(0.7)).frame(width: 34, height: 3)
                                Capsule().fill(.white.opacity(0.35)).frame(width: 22, height: 3)
                            }
                        }
                    case .minimal:
                        IslandLevelMeter(state: driver.state)
                            .padding(.horizontal, -14)
                    }
                }
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(visual.displayName)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .accentColor : .secondary)
                    .lineLimit(1)
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.accentColor : Color.primary.opacity(0.1),
                            lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    // MARK: Waveform styles — one live thumbnail each

    private var waveformStyleGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
            spacing: 8
        ) {
            ForEach(IslandWaveformStyle.allCases, id: \.self) { style in
                let selected = settings.islandWaveformStyle == style
                Button {
                    settings.islandWaveformStyle = style
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7).fill(Color.black)
                            IslandWaveformBand(state: driver.state, style: style)
                                .padding(.horizontal, 2)
                        }
                        .frame(height: 38)

                        Text(style.rawValue)
                            .font(.system(size: 9.5, weight: selected ? .semibold : .regular))
                            .foregroundColor(selected ? .accentColor : .secondary)
                            .lineLimit(1)
                    }
                    .padding(3)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(selected ? Color.accentColor : Color.primary.opacity(0.08),
                                    lineWidth: selected ? 1.5 : 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Glow palettes — gradient swatches

    private var paletteRow: some View {
        HStack(spacing: 10) {
            ForEach(IslandGlowPalette.allCases, id: \.self) { palette in
                let selected = settings.islandGlowPalette == palette
                Button {
                    settings.islandGlowPalette = palette
                    driver.replaySession()
                } label: {
                    VStack(spacing: 4) {
                        Circle()
                            .fill(palette.stroke)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle().fill(Color.black).frame(width: 14, height: 14)
                            )
                            .overlay(
                                Circle().stroke(
                                    selected ? Color.accentColor : Color.primary.opacity(0.15),
                                    lineWidth: selected ? 2 : 1
                                )
                            )
                        Text(palette.rawValue)
                            .font(.system(size: 9, weight: selected ? .semibold : .regular))
                            .foregroundColor(selected ? .accentColor : .secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: Reveal styles — replay on pick

    private var revealRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Appear animation")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                ForEach(IslandRevealStyle.allCases, id: \.self) { style in
                    let selected = settings.islandRevealStyle == style
                    Button {
                        settings.islandRevealStyle = style
                        driver.replayReveal()
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: revealIcon(style))
                                .font(.system(size: 13, weight: .medium))
                            Text(style.rawValue)
                                .font(.system(size: 9.5, weight: selected ? .semibold : .regular))
                        }
                        .foregroundColor(selected ? .accentColor : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selected ? Color.accentColor : Color.primary.opacity(0.08),
                                        lineWidth: selected ? 1.5 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Picking one replays it in the preview above.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private func revealIcon(_ style: IslandRevealStyle) -> String {
        switch style {
        case .slide: return "arrow.down.to.line"
        case .unfurl: return "rectangle.expand.vertical"
        case .bloom: return "circle.circle"
        case .drift: return "wind"
        }
    }

    // MARK: Our chrome

    private var elementsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Elements")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                elementChip("Recording dot", icon: "record.circle", isOn: $settings.islandShowRecordingDot)
                elementChip("Timer", icon: "timer", isOn: $settings.islandShowTimer)
                elementChip("Stop button", icon: "stop.circle", isOn: $settings.islandShowStopButton)
                Spacer()
            }
            Text("With everything off the island shows only the visual — recording still stops with the hotkey or Esc.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A toggle drawn as a selectable chip, matching the section's card language: filled
    /// accent with a checkmark when on, quiet outline when off.
    private func elementChip(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        let on = isOn.wrappedValue
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { isOn.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark.circle.fill" : icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
            )
            .overlay(
                Capsule().stroke(on ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: 1)
            )
            .foregroundColor(on ? .accentColor : .secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(on ? "Shown on the island — click to hide" : "Hidden — click to show")
    }
}

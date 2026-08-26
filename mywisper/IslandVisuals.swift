//
//  IslandVisuals.swift
//  mywisper
//
//  The island's voice-reactive visuals, ported from Talkify's HUD
//  (github.com/tornikegomareli/Talkify, which itself credits: "Writing a
//  High-Performance Audio Wave in SwiftUI" (Article), jonathanjr3/AudioWaveform
//  (Capsules / Chart Line / Chart Area), lkora/WaveformScrubber (Dots / Curve),
//  AudioKit/Waveform (Filled), and alfianlosari/SiriWaveView (Siri Wave, MIT,
//  © 2019 Noah Chalifour).
//
//  All styles are fed by the same live level history on OverlayState. The
//  WWDC26-style sheen shader (WaveformSheen.metal) needs SwiftUI's ShaderLibrary
//  and is gated to macOS 14+; everything else runs on our 13.3 target.
//

import SwiftUI
import Charts

// MARK: - Selectable styles (Settings picks)

/// The voice-reactive visual shown in the island's band while recording.
enum IslandVoiceVisual: String, CaseIterable {
    case waveform = "waveform"
    case glow = "glow"
    case compact = "compact"
    case minimal = "minimal"

    var displayName: String {
        switch self {
        case .waveform: return "Waveform"
        case .glow: return "Edge Glow"
        case .compact: return "Compact"
        case .minimal: return "Minimal"
        }
    }
}

/// The waveform looks, each mimicking its reference implementation.
enum IslandWaveformStyle: String, CaseIterable {
    case article = "Article"
    case silver = "Silver"
    case capsules = "Capsules"
    case chartLine = "Chart Line"
    case chartArea = "Chart Area"
    case dots = "Dots"
    case curve = "Curve"
    case filled = "Filled"
    case siriWave = "Siri Wave"
}

/// How the island enters and leaves. All styles keep the shape's top edge glued
/// to the screen edge: bounce is expressed in scale anchored at the top, never
/// in position, so overshoot can't open a gap above the shape.
enum IslandRevealStyle: String, CaseIterable {
    case slide = "Slide"
    case unfurl = "Unfurl"
    case bloom = "Bloom"
    case drift = "Drift"
}

/// The Edge Glow color palettes: each colors the beam and the particle cloud
/// together so the whole visual speaks one language.
enum IslandGlowPalette: String, CaseIterable {
    case spectrum = "Spectrum"
    case silver = "Silver"
    case aurora = "Aurora"
    case sunset = "Sunset"
    case ocean = "Ocean"
    case mono = "Mono"

    var stroke: AnyShapeStyle {
        AnyShapeStyle(
            .angularGradient(
                stops: stops,
                center: .center,
                startAngle: Angle(radians: .zero),
                endAngle: Angle(radians: .pi * 2)
            )
        )
    }

    private var stops: [Gradient.Stop] {
        switch self {
        case .spectrum:
            return [
                .init(color: .blue, location: 0.0),
                .init(color: .purple, location: 0.2),
                .init(color: .red, location: 0.4),
                .init(color: .mint, location: 0.5),
                .init(color: .indigo, location: 0.7),
                .init(color: .pink, location: 0.9),
                .init(color: .blue, location: 1.0),
            ]
        case .silver:
            return [
                .init(color: .white, location: 0.0),
                .init(color: Color(red: 0.62, green: 0.72, blue: 1.0), location: 0.3),
                .init(color: .white, location: 0.5),
                .init(color: Color(red: 0.75, green: 0.78, blue: 0.95), location: 0.75),
                .init(color: .white, location: 1.0),
            ]
        case .aurora:
            return [
                .init(color: .mint, location: 0.0),
                .init(color: .teal, location: 0.3),
                .init(color: .green, location: 0.5),
                .init(color: .cyan, location: 0.75),
                .init(color: .mint, location: 1.0),
            ]
        case .sunset:
            return [
                .init(color: .orange, location: 0.0),
                .init(color: .red, location: 0.35),
                .init(color: .pink, location: 0.6),
                .init(color: .purple, location: 0.85),
                .init(color: .orange, location: 1.0),
            ]
        case .ocean:
            return [
                .init(color: .blue, location: 0.0),
                .init(color: .cyan, location: 0.35),
                .init(color: .indigo, location: 0.65),
                .init(color: Color(red: 0.0, green: 0.1, blue: 0.45), location: 0.85),
                .init(color: .blue, location: 1.0),
            ]
        case .mono:
            return [
                .init(color: .white, location: 0.0),
                .init(color: .white, location: 1.0),
            ]
        }
    }

    /// The particle cloud's colors, cycled across the motes.
    var particleColors: [SIMD4<Float>] {
        switch self {
        case .spectrum:
            return [
                SIMD4(0.35, 0.45, 1.0, 1.0),
                SIMD4(0.75, 0.4, 1.0, 1.0),
                SIMD4(1.0, 0.5, 0.75, 1.0),
            ]
        case .silver:
            return [
                SIMD4(0.62, 0.72, 1.0, 1.0),
                SIMD4(0.85, 0.90, 1.0, 1.0),
                SIMD4(1.0, 1.0, 1.0, 1.0),
            ]
        case .aurora:
            return [
                SIMD4(0.4, 1.0, 0.8, 1.0),
                SIMD4(0.3, 0.85, 0.85, 1.0),
                SIMD4(0.9, 1.0, 0.95, 1.0),
            ]
        case .sunset:
            return [
                SIMD4(1.0, 0.6, 0.25, 1.0),
                SIMD4(1.0, 0.45, 0.6, 1.0),
                SIMD4(1.0, 0.9, 0.8, 1.0),
            ]
        case .ocean:
            return [
                SIMD4(0.25, 0.75, 1.0, 1.0),
                SIMD4(0.3, 0.45, 1.0, 1.0),
                SIMD4(0.85, 0.95, 1.0, 1.0),
            ]
        case .mono:
            return [
                SIMD4(1.0, 1.0, 1.0, 1.0),
                SIMD4(0.9, 0.9, 0.9, 1.0),
                SIMD4(0.75, 0.75, 0.75, 1.0),
            ]
        }
    }
}

/// Tokens shared across the visuals.
enum IslandVisualTokens {
    /// The dead-microphone state's motionless amber — a dead microphone must
    /// look different from silence.
    static let deadMicAmber = Color(red: 1.0, green: 0.6, blue: 0.16)
}

// MARK: - Wave shapes (Talkify's WaveShapes.swift)

/// An open, smoothed line through the samples, shifted left by
/// `scrollProgress` of one slot so consecutive buffers connect seamlessly.
struct SmoothLineShape: Shape {
    let samples: [Float]
    let scrollProgress: Double

    func path(in rect: CGRect) -> Path {
        guard samples.count > 2 else { return Path() }
        let step = rect.width / CGFloat(samples.count - 2)
        let offset = CGFloat(scrollProgress) * step

        let points = samples.enumerated().map { index, sample in
            CGPoint(
                x: rect.minX + CGFloat(index) * step - offset,
                y: rect.midY - max(0.75, CGFloat(sample) * rect.height / 2)
            )
        }

        var path = Path()
        path.move(to: points[0])
        for i in 1..<points.count {
            let previous = points[i - 1]
            let current = points[i]
            let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: mid, control: previous)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

/// One vertical bar per sample, centered on the midline. `rounded` and
/// `perceptual` (square-root heights) split the Article and Silver looks.
struct AudioWaveShape: Shape {
    let samples: [Float]
    let spacing: CGFloat
    var rounded = true
    var perceptual = true

    func path(in rect: CGRect) -> Path {
        guard !samples.isEmpty else { return Path() }
        let count = CGFloat(samples.count)
        let barWidth = max(1, (rect.width - spacing * (count - 1)) / count)

        var path = Path()
        var x = rect.minX
        for sample in samples {
            let scaled = perceptual ? CGFloat(sample).squareRoot() : CGFloat(sample)
            let height = max(2, scaled * rect.height)
            let bar = CGRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height)
            if rounded {
                path.addRoundedRect(
                    in: bar,
                    cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2)
                )
            } else {
                path.addRect(bar)
            }
            x += barWidth + spacing
        }
        return path
    }
}

/// WaveformScrubber's DotDrawer: a mirrored pair of dots per sample.
struct DotWaveShape: Shape {
    let samples: [Float]
    let dotRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard !samples.isEmpty else { return Path() }
        let spacing = rect.width / CGFloat(samples.count)
        var path = Path()
        for (index, sample) in samples.enumerated() {
            let x = rect.minX + CGFloat(index) * spacing
            let halfHeight = CGFloat(sample) * rect.height / 2
            for y in [rect.midY - halfHeight, rect.midY + halfHeight] {
                path.addEllipse(in: CGRect(
                    x: x - dotRadius,
                    y: y - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                ))
            }
        }
        return path
    }
}

/// WaveformScrubber's BezierCurveDrawer, simplified: a smooth symmetric
/// filled shape through midpoint quadratic curves.
struct CurveWaveShape: Shape {
    let samples: [Float]

    func path(in rect: CGRect) -> Path {
        guard samples.count > 1 else { return Path() }
        let stepX = rect.width / CGFloat(samples.count - 1)
        let top = samples.enumerated().map { index, sample in
            CGPoint(
                x: rect.minX + CGFloat(index) * stepX,
                y: rect.midY - max(1, CGFloat(sample) * rect.height / 2)
            )
        }

        var path = Path()
        path.move(to: top[0])
        addSmoothLine(through: top, to: &path)
        let bottom = top.reversed().map { CGPoint(x: $0.x, y: 2 * rect.midY - $0.y) }
        path.addLine(to: bottom[0])
        addSmoothLine(through: bottom, to: &path)
        path.closeSubpath()
        return path
    }

    private func addSmoothLine(through points: [CGPoint], to path: inout Path) {
        for i in 1..<points.count {
            let previous = points[i - 1]
            let current = points[i]
            let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: mid, control: previous)
        }
        path.addLine(to: points[points.count - 1])
    }
}

/// AudioKit Waveform's look: a continuous symmetric min/max region.
struct FilledWaveShape: Shape {
    let samples: [Float]

    func path(in rect: CGRect) -> Path {
        guard samples.count > 1 else { return Path() }
        let stepX = rect.width / CGFloat(samples.count - 1)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        for (index, sample) in samples.enumerated() {
            path.addLine(to: CGPoint(
                x: rect.minX + CGFloat(index) * stepX,
                y: rect.midY - max(0.75, CGFloat(sample) * rect.height / 2)
            ))
        }
        for (index, sample) in samples.enumerated().reversed() {
            path.addLine(to: CGPoint(
                x: rect.minX + CGFloat(index) * stepX,
                y: rect.midY + max(0.75, CGFloat(sample) * rect.height / 2)
            ))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Waveform band (all 9 styles)

/// The live waveform strip filling the island's band. Newest level on the right.
struct IslandWaveformBand: View {
    @ObservedObject var state: OverlayState
    let style: IslandWaveformStyle

    @State private var start = Date()
    @State private var waveSize = CGSize(width: 1, height: 1)

    /// Chart Line and Siri Wave carry their own treatment — the sheen shader
    /// and the bar styles' side margins would only muddy them.
    private var carriesOwnTreatment: Bool {
        style == .chartLine || style == .siriWave
    }

    var body: some View {
        Group {
            if carriesOwnTreatment {
                styledWave
            } else if #available(macOS 14.0, *) {
                TimelineView(.animation) { context in
                    styledWave
                        // WWDC26-style finish over the drawn pixels: chromatic
                        // edge fringing, a metallic specular sweep, soft bloom
                        // (WaveformSheen.metal).
                        .layerEffect(
                            ShaderLibrary.waveformSheen(
                                .float2(waveSize),
                                .float(Float(context.date.timeIntervalSince(start))),
                                .float(state.audioLevel)
                            ),
                            maxSampleOffset: CGSize(width: 8, height: 8)
                        )
                }
            } else {
                styledWave
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.onAppear { waveSize = proxy.size }
                    .onChange(of: proxy.size) { waveSize = $0 }
            }
        )
        .animation(.linear(duration: 0.05), value: state.levelHistory)
        // Full-width styles run edge to edge; the bar styles keep margins.
        .padding(.horizontal, carriesOwnTreatment ? 0 : 16)
        .padding(.vertical, 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var styledWave: some View {
        switch style {
        case .article:
            AudioWaveShape(samples: state.levelHistory, spacing: 2, rounded: false, perceptual: false)
                .fill(silver)
        case .silver:
            AudioWaveShape(samples: state.levelHistory, spacing: 3, rounded: true, perceptual: true)
                .fill(silver)
        case .capsules:
            capsules
        case .chartLine:
            IslandChartLineWave(state: state)
        case .chartArea:
            areaChart
        case .dots:
            DotWaveShape(samples: state.levelHistory, dotRadius: 1.6)
                .fill(silver)
        case .curve:
            CurveWaveShape(samples: state.levelHistory)
                .fill(silver)
        case .filled:
            FilledWaveShape(samples: state.levelHistory)
                .fill(silver)
        case .siriWave:
            IslandSiriWave(state: state)
        }
    }

    /// One color language for every style: a hot white body cooling at the
    /// extremes, faint blue-violet fringe. Amber when the microphone dies.
    private var silver: AnyShapeStyle {
        state.isAudioAlive
            ? AnyShapeStyle(LinearGradient(
                colors: [
                    Color(red: 0.62, green: 0.72, blue: 1.0).opacity(0.75),
                    .white,
                    Color(red: 0.62, green: 0.72, blue: 1.0).opacity(0.75),
                ],
                startPoint: .top,
                endPoint: .bottom
            ))
            : AnyShapeStyle(Color.orange.opacity(0.55))
    }

    /// AudioWaveform's capsule mode: dampened heights, width-derived bars.
    private var capsules: some View {
        GeometryReader { proxy in
            let values = state.levelHistory
            let step = proxy.size.width / CGFloat(values.count)
            let barWidth = max(step * 0.55, 1)
            HStack(alignment: .center, spacing: step - barWidth) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(silver)
                        .frame(
                            width: barWidth,
                            height: max(barWidth, CGFloat(value) * 0.75 * proxy.size.height)
                        )
                        .frame(maxHeight: .infinity, alignment: .center)
                }
            }
        }
    }

    /// AudioWaveform's area mode, straight from Swift Charts.
    private var areaChart: some View {
        Chart(Array(state.levelHistory.enumerated()), id: \.offset) { index, value in
            AreaMark(x: .value("t", index), y: .value("level", value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(silver)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...1)
    }
}

// MARK: - Chart Line (conveyor renderer with glass treatment)

/// The Chart Line look rendered as a conveyor: each level tick shifts the
/// buffer one slot, so the shape interpolates the scroll offset against the
/// tick clock and the points glide left continuously. A crisp core over two
/// glow passes, a glass-floor reflection, and a travelling specular band.
struct IslandChartLineWave: View {
    @ObservedObject var state: OverlayState

    @State private var samples: [Float] = []
    @State private var lastTick = Date.distantPast
    /// Measured time between level ticks, smoothed; scroll speed follows it.
    @State private var tickInterval: Double = 0.033

    var body: some View {
        TimelineView(.animation) { context in
            let progress = min(1, max(0, context.date.timeIntervalSince(lastTick) / tickInterval))
            let level = Double(state.audioLevel)
            let shape = SmoothLineShape(samples: samples, scrollProgress: progress)

            if state.isAudioAlive {
                ZStack {
                    // Ambient under-glow: a wide soft pool of light beneath
                    // the line, breathing with the voice.
                    Ellipse()
                        .fill(Self.silver)
                        .frame(height: 20)
                        .padding(.horizontal, 40)
                        .blur(radius: 18)
                        .opacity(0.08 + 0.22 * level)

                    // Glass-floor reflection: the wave mirrored about its
                    // rest line, soft and fading downward.
                    shape
                        .stroke(
                            Self.silver,
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                        )
                        .scaleEffect(y: -1)
                        .blur(radius: 2.5)
                        .opacity(0.16 + 0.22 * level)
                        .mask(
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.8), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // Wide halo breathing with the voice.
                    shape
                        .stroke(
                            Self.silver,
                            style: StrokeStyle(
                                lineWidth: 4 + 8 * level,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                        .blur(radius: 9)
                        .opacity(0.2 + 0.6 * level)
                    // Tight bloom hugging the core.
                    shape
                        .stroke(
                            Self.silver,
                            style: StrokeStyle(
                                lineWidth: 2.5 + 3 * level,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                        .blur(radius: 2.5)
                        .opacity(0.8)
                    // Crisp white-hot core — never blurred.
                    shape
                        .stroke(
                            .white.opacity(0.75 + 0.25 * level),
                            style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                        )
                    // Metallic specular: a soft band of extra light sweeping
                    // along the line.
                    shape
                        .stroke(
                            .white,
                            style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
                        )
                        .blur(radius: 0.8)
                        .mask(specularBand(at: context.date))
                }
            } else {
                shape
                    .stroke(
                        Color.orange.opacity(0.55),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )
            }
        }
        .clipped()
        .onChange(of: state.levelHistory) { new in
            let now = Date()
            let gap = now.timeIntervalSince(lastTick)
            if gap < 0.1 {
                tickInterval = tickInterval * 0.8 + gap * 0.2
            }
            samples = new
            lastTick = now
        }
    }

    /// Metallic silver: white body cooling into a faint blue-gray at the ends.
    private static let silver = LinearGradient(
        colors: [
            Color(red: 0.68, green: 0.74, blue: 0.88).opacity(0.85),
            .white,
            Color(red: 0.82, green: 0.86, blue: 0.95),
            .white,
            Color(red: 0.68, green: 0.74, blue: 0.88).opacity(0.85),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// A soft bright band ping-ponging across the strip; masking the extra
    /// specular stroke with it makes the light travel along the line.
    private func specularBand(at date: Date) -> some View {
        GeometryReader { proxy in
            let phase = date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1000) / 3.2
            let cycle = phase.truncatingRemainder(dividingBy: 2)
            let lin = cycle < 1 ? cycle : 2 - cycle
            let eased = lin * lin * (3 - 2 * lin)
            let bandWidth = proxy.size.width * 0.3

            LinearGradient(
                colors: [.clear, .white, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: bandWidth)
            .offset(x: eased * (proxy.size.width + bandWidth) - bandWidth)
        }
    }
}

// MARK: - Siri Wave (alfianlosari/SiriWaveView, MIT © 2019 Noah Chalifour)

/// The classic Siri 9-style wave: a support line and three overlapping colored
/// waves; every power change animates each wave toward a fresh random
/// four-curve composition over 0.3s, which is what makes the motion roll.
struct IslandSiriWave: View {
    private static let colors: [Color] = [
        Color(red: 173 / 255, green: 57 / 255, blue: 76 / 255),
        Color(red: 48 / 255, green: 220 / 255, blue: 155 / 255),
        Color(red: 25 / 255, green: 122 / 255, blue: 255 / 255),
    ]
    private static let amber = Color.orange.opacity(0.55)

    @ObservedObject var state: OverlayState

    var body: some View {
        let alive = state.isAudioAlive
        ZStack {
            supportLine(alive: alive)
            ForEach(0..<Self.colors.count, id: \.self) { index in
                SiriSingleWave(
                    power: alive ? Double(state.audioLevel) : 0,
                    color: alive ? Self.colors[index] : Self.amber
                )
            }
        }
        .blendMode(.lighten)
        .drawingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func supportLine(alive: Bool) -> some View {
        GeometryReader { proxy in
            Path { path in
                let centerY = proxy.size.height / 2
                path.move(to: CGPoint(x: 0, y: centerY))
                path.addLine(to: CGPoint(x: proxy.size.width, y: centerY))
            }
            .stroke(alive ? Color.white : Self.amber, lineWidth: 2)
            .opacity(0.5)
        }
    }
}

/// One colored wave: holds the current composition and animates to a new
/// random one whenever the power changes.
private struct SiriSingleWave: View {
    let power: Double
    let color: Color

    @State private var wave = SiriWave.random(power: 0)

    var body: some View {
        SiriWaveShape(wave: wave)
            .fill(color)
            .onChange(of: power) { newPower in
                withAnimation(.linear(duration: 0.3)) {
                    wave = .random(power: newPower)
                }
            }
    }
}

/// One sine component of a wave.
struct SiriWaveCurve: Equatable {
    var power: Double
    var A: Double
    var k: Double
    var t: Double

    static func random(power: Double) -> SiriWaveCurve {
        SiriWaveCurve(
            power: power,
            A: .random(in: 0.1...1.0),
            k: .random(in: 0.6...0.9),
            t: .random(in: -1.0...4.0)
        )
    }
}

/// A composition of four curves, of which `useCurves` render.
struct SiriWave: Equatable {
    var power: Double
    var curves: [SiriWaveCurve]
    var useCurves: Int

    static func random(power: Double) -> SiriWave {
        SiriWave(
            power: power,
            curves: (0..<4).map { _ in .random(power: power) },
            useCurves: Int.random(in: 2...4)
        )
    }
}

// The source's workaround, kept as-is: arrays cannot be animatable data, so
// the four curves' parameters flatten into nested AnimatablePairs.
extension SiriWave: Animatable {
    typealias AnimatableData = AnimatablePair<
        AnimatablePair<
            AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>,
            AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>
        >,
        AnimatablePair<
            AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>,
            AnimatablePair<
                AnimatablePair<Double, Double>,
                AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>
            >
        >
    >

    var animatableData: AnimatableData {
        get {
            .init(
                .init(
                    .init(.init(curves[0].A, curves[0].power), .init(curves[0].k, curves[0].t)),
                    .init(.init(curves[1].A, curves[1].power), .init(curves[1].k, curves[1].t))
                ),
                .init(
                    .init(.init(curves[2].A, curves[2].power), .init(curves[2].k, curves[2].t)),
                    .init(
                        .init(curves[3].A, curves[3].power),
                        .init(.init(curves[3].k, curves[3].t), .init(power, .zero))
                    )
                )
            )
        }
        set {
            curves[0].A = newValue.first.first.first.first
            curves[0].power = newValue.first.first.first.second
            curves[0].k = newValue.first.first.second.first
            curves[0].t = newValue.first.first.second.second

            curves[1].A = newValue.first.second.first.first
            curves[1].power = newValue.first.second.first.second
            curves[1].k = newValue.first.second.second.first
            curves[1].t = newValue.first.second.second.second

            curves[2].A = newValue.second.first.first.first
            curves[2].power = newValue.second.first.first.second
            curves[2].k = newValue.second.first.second.first
            curves[2].t = newValue.second.first.second.second

            curves[3].A = newValue.second.second.first.first
            curves[3].power = newValue.second.second.first.second
            curves[3].k = newValue.second.second.second.first.first
            curves[3].t = newValue.second.second.second.first.second

            power = newValue.second.second.second.second.first
        }
    }
}

/// The source's wave geometry: each active curve is an attenuated sine
/// (|A·sin(kx−t)| under a bell), the curves' upper envelope is taken per
/// column, then mirrored about the midline into the filled blob.
struct SiriWaveShape: Shape {
    var wave: SiriWave

    var animatableData: SiriWave.AnimatableData {
        get { wave.animatableData }
        set { wave.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let columns = Array(stride(from: -rect.midX, to: rect.midX, by: 1.0))
        var upper = [CGPoint](
            repeating: CGPoint(x: 0, y: rect.midY),
            count: columns.count
        )

        for index in 0..<wave.useCurves {
            let curve = wave.curves[index]
            let A = curve.A * Double(rect.midY) * wave.power

            for (j, graphX) in columns.enumerated() {
                let scaledX = graphX / (rect.midX / 9.0)
                let x = rect.midX + graphX
                let y = attenuatedSine(
                    x: Double(scaledX), A: A, k: curve.k, t: curve.t
                ) + Double(rect.midY)
                upper[j] = CGPoint(x: x, y: max(upper[j].y, y))
            }
        }

        let mirrored = upper.map { CGPoint(x: $0.x, y: 2 * rect.midY - $0.y) }

        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLines(upper + mirrored)
        return path
    }

    private func attenuatedSine(
        x: Double, A: Double, k: Double, t: Double
    ) -> Double {
        let sine = A * sin((k * x) - t)
        let K = 4.0
        let shiftedT = t - (Double.pi / 2)
        let bell = pow(K / (K + pow((k * x) - shiftedT, 2)), K)
        return abs(sine * bell)
    }
}

// MARK: - Compact (Dynamic Island caption look)

/// The Compact visual's voice indicator: a tiny five-bar equalizer beside the live draft,
/// after iOS's Dynamic Island sound dots. Each bar rides the microphone level with its own
/// phase so the cluster reads as sound rather than a meter; silence settles the bars into
/// resting dots, and a dead microphone freezes them amber.
struct IslandCompactIndicator: View {
    private static let barCount = 5
    private static let restingHeight: CGFloat = 3

    @ObservedObject var state: OverlayState

    var body: some View {
        let live = state.isRecording && state.isAudioAlive
        TimelineView(.animation(paused: !live)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let level = Double(state.audioLevel)
            let alive = state.isAudioAlive
            HStack(spacing: 2.5) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    Capsule()
                        .fill(alive ? Color.white.opacity(0.9) : .orange.opacity(0.6))
                        .frame(
                            width: 2.5,
                            height: barHeight(index: index, time: time, level: level, live: live)
                        )
                }
            }
            .frame(height: 14)
        }
        .animation(.easeOut(duration: 0.25), value: state.isRecording)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func barHeight(index: Int, time: TimeInterval, level: Double, live: Bool) -> CGFloat {
        guard live else { return Self.restingHeight }
        // Per-bar phase offsets keep neighbors out of sync, so the cluster shimmers with
        // speech instead of pumping as one block.
        let wobble = 0.5 + 0.5 * sin(time * 9 + Double(index) * 1.7)
        return Self.restingHeight + CGFloat(level * wobble) * 11
    }
}

/// The Compact band: indicator beside the head-truncated live draft — the newest words are
/// what the speaker checks. Engines that can't stream text show a listening placeholder.
struct IslandCompactBand: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        HStack(spacing: 10) {
            IslandCompactIndicator(state: state)
            Text(state.liveText.isEmpty ? "Listening…" : state.liveText)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(state.liveText.isEmpty ? .white.opacity(0.55) : .white)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(nil, value: state.liveText)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Minimal level meter

/// A quiet horizontal level bar. A dead microphone turns the bar amber;
/// silence just sits near empty.
struct IslandLevelMeter: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule()
                    .fill(state.isAudioAlive ? Color.white.opacity(0.85) : .orange.opacity(0.6))
                    .frame(width: max(6, proxy.size.width * CGFloat(state.audioLevel)))
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 30)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

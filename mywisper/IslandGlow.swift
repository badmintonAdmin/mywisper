//
//  IslandGlow.swift
//  mywisper
//
//  The Edge Glow visual, ported from Talkify's HUD: the island's open
//  silhouette (down the left flank, across the bottom, up the right flank —
//  never the hidden top edge) is stroked with an angular palette gradient
//  three times — a crisp line and two blurred copies — and a shader
//  (EdgeGlow.metal) masks that picture by distance from an origin that sweeps
//  the silhouette, corner to notch and back, eased at the turnarounds. The
//  mask blooms in at session start and breathes with the microphone level.
//  A particle cloud (ParticleCloud.metal, Metal compute into an MTKView) can
//  chase the same origin. A one-shot ripple (Ripple.metal) rolls across the
//  housing at session start.
//
//  The shader mask and ripple need SwiftUI ShaderLibrary (macOS 14+); on 13.x
//  the beam renders unmasked with voice-driven opacity instead.
//

import SwiftUI
import MetalKit

// MARK: - Edge Glow beam

struct IslandEdgeGlowView: View {
    /// Room the blurred strokes get beyond the shape's border.
    static let spill: CGFloat = 24
    /// Duration of the bloom-in ramp.
    static let rampDuration: TimeInterval = 0.4
    /// Stroke width: crisp line at half this, blurred copies at full.
    static let lineWidth: Double = 6
    /// Blur of the outer halo stroke (the inner copy runs at half).
    static let blurRadius: Double = 12
    /// Seconds for one end-to-end sweep of the silhouette.
    static let sweepDuration: TimeInterval = 4.0

    @ObservedObject var state: OverlayState
    let palette: IslandGlowPalette
    let cornerRadius: CGFloat
    let topFilletRadius: CGFloat

    /// Reset on every session start so the sweep begins at bottom-center,
    /// directly under the housing — and the ramp blooms in from zero.
    @State private var sweepStart = Date()

    var body: some View {
        GeometryReader { proxy in
            let listening = state.isRecording
            TimelineView(.animation(paused: !listening)) { context in
                let size = proxy.size
                let alive = state.isAudioAlive
                let level = Double(state.audioLevel)
                let elapsed = context.date.timeIntervalSince(sweepStart)
                // Session ramp computed from the sweep clock — blooms in over
                // rampDuration at each session start.
                let progress = min(1.0, max(0.0, elapsed / Self.rampDuration))
                // The voice shows in two registers: brightness — resting near
                // a constant so the halo never starves, flaring with speech —
                // and body, the strokes swelling up to double.
                let amplitude = alive ? 1.8 + 1.2 * level : 1.5
                let lineWidth = Self.lineWidth * (1 + level)
                let blurRadius = Self.blurRadius * (1 + 0.5 * level)
                let origin = IslandGlowSilhouetteShape.point(
                    atArcFraction: Self.sweepFraction(at: elapsed),
                    cornerRadius: cornerRadius,
                    topFilletRadius: topFilletRadius,
                    inset: Self.spill,
                    in: size
                )
                let beam = IslandGlowSilhouetteShape(
                    cornerRadius: cornerRadius,
                    topFilletRadius: topFilletRadius,
                    inset: Self.spill
                )
                .glow(
                    fill: alive ? palette.stroke : AnyShapeStyle(IslandVisualTokens.deadMicAmber),
                    lineWidth: lineWidth,
                    blurRadius: blurRadius
                )

                if #available(macOS 14.0, *) {
                    beam.colorEffect(
                        ShaderLibrary.edgeGlow(
                            .float2(origin),
                            .float2(size),
                            .float(amplitude),
                            .float(progress)
                        ),
                        isEnabled: listening
                    )
                } else {
                    // No shader mask pre-Sonoma: the whole beam breathes with
                    // the voice instead of a travelling origin glow.
                    beam.opacity(progress * (0.35 + 0.5 * level))
                }
            }
        }
        .padding(.horizontal, -Self.spill)
        .padding(.bottom, -Self.spill)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: state.sessionEpoch) { _ in
            sweepStart = Date()
        }
    }

    /// The eased ping-pong position along the silhouette at time `t` (left
    /// tip → bottom → right tip → back), phase-shifted so t = 0 lands at
    /// bottom-center. Shared with the particle cloud so the motes chase the
    /// same point the beam highlights.
    static func sweepFraction(at t: TimeInterval) -> Double {
        let phase = ((t / sweepDuration) + 0.5)
            .truncatingRemainder(dividingBy: 2.0)
        let linear = phase < 1.0 ? phase : 2.0 - phase
        // Mostly linear: full smoothstep easing parks the origin at each
        // flank tip, which reads as the glow stopping to wait. A light blend
        // keeps constant travel with just a softened turnaround.
        let eased = linear * linear * (3.0 - 2.0 * linear)
        return linear + (eased - linear) * 0.3
    }
}

/// The island's open silhouette as a strokable path: left flank, bottom run
/// with its two corner arcs, right flank. The top edge is the screen edge and
/// is never drawn.
struct IslandGlowSilhouetteShape: Shape {
    var cornerRadius: CGFloat
    /// Radius of the physical top housing fillets; zero keeps square corners
    /// on displays without a measured notch.
    var topFilletRadius: CGFloat = 0
    /// Distance from the view's left/right/bottom edges to the silhouette.
    var inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + inset
        let right = rect.maxX - inset
        let bottom = rect.maxY - inset
        let radius = min(cornerRadius, max(0, (bottom - rect.minY) / 2))
        let topRadius = min(topFilletRadius, max(0, (bottom - rect.minY) / 2))

        var path = Path()
        if topRadius > 0 {
            path.move(to: CGPoint(x: left - topRadius, y: rect.minY))
            path.addArc(
                tangent1End: CGPoint(x: left, y: rect.minY),
                tangent2End: CGPoint(x: left, y: rect.minY + topRadius),
                radius: topRadius
            )
        } else {
            path.move(to: CGPoint(x: left, y: rect.minY))
        }
        path.addLine(to: CGPoint(x: left, y: bottom - radius))
        path.addArc(
            tangent1End: CGPoint(x: left, y: bottom),
            tangent2End: CGPoint(x: left + radius, y: bottom),
            radius: radius
        )
        path.addLine(to: CGPoint(x: right - radius, y: bottom))
        path.addArc(
            tangent1End: CGPoint(x: right, y: bottom),
            tangent2End: CGPoint(x: right, y: bottom - radius),
            radius: radius
        )
        if topRadius > 0 {
            path.addArc(
                tangent1End: CGPoint(x: right, y: rect.minY),
                tangent2End: CGPoint(x: right + topRadius, y: rect.minY),
                radius: topRadius
            )
        } else {
            path.addLine(to: CGPoint(x: right, y: rect.minY))
        }
        return path
    }

    /// The point at `fraction` (0…1) of the silhouette's arc length, from the
    /// left flank's tip to the right flank's tip. Mirrors `path(in:)`.
    static func point(
        atArcFraction fraction: Double,
        cornerRadius: CGFloat,
        topFilletRadius: CGFloat = 0,
        inset: CGFloat,
        in size: CGSize
    ) -> CGPoint {
        let left = inset
        let right = size.width - inset
        let bottom = size.height - inset
        let radius = min(cornerRadius, bottom / 2)
        let topRadius = min(topFilletRadius, bottom / 2)

        let flank = max(0, bottom - radius - topRadius)
        let topCorner = Double.pi * topRadius / 2
        let corner = Double.pi * radius / 2
        let run = (right - left) - 2 * radius
        let total = 2 * flank + 2 * corner + run + 2 * topCorner
        var distance = min(max(fraction, 0), 1) * total
        if topRadius > 0 {
            if distance < topCorner {
                let angle = -Double.pi / 2 + distance / topRadius
                return CGPoint(
                    x: left - topRadius + topRadius * cos(angle),
                    y: topRadius + topRadius * sin(angle)
                )
            }
            distance -= topCorner
        }
        if distance < flank {
            return CGPoint(x: left, y: topRadius + distance)
        }
        distance -= flank
        if distance < corner {
            let angle = Double.pi - distance / radius
            return CGPoint(
                x: left + radius + radius * cos(angle),
                y: bottom - radius + radius * sin(angle)
            )
        }
        distance -= corner
        if distance < run {
            return CGPoint(x: left + radius + distance, y: bottom)
        }
        distance -= run
        if distance < corner {
            let angle = Double.pi / 2 - distance / radius
            return CGPoint(
                x: right - radius + radius * cos(angle),
                y: bottom - radius + radius * sin(angle)
            )
        }
        distance -= corner
        if distance < flank {
            return CGPoint(x: right, y: bottom - radius - distance)
        }
        distance -= flank
        if topRadius > 0 {
            let angle = Double.pi + distance / topRadius
            return CGPoint(
                x: right + topRadius + topRadius * cos(angle),
                y: topRadius + topRadius * sin(angle)
            )
        }
        return CGPoint(x: right, y: 0)
    }
}

// The gist's GlowModifier, verbatim: a crisp stroke plus two blurred copies.
private extension Shape {
    func glow(
        fill: some ShapeStyle,
        lineWidth: Double,
        blurRadius: Double = 8.0,
        lineCap: CGLineCap = .round
    ) -> some View {
        stroke(style: StrokeStyle(lineWidth: lineWidth / 2, lineCap: lineCap))
            .fill(fill)
            .overlay {
                stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: lineCap))
                    .fill(fill)
                    .blur(radius: blurRadius)
            }
            .overlay {
                stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: lineCap))
                    .fill(fill)
                    .blur(radius: blurRadius / 2)
            }
    }
}

// MARK: - One-shot ripple across the housing (macOS 14+)

/// Hosts the ripple shader (Ripple.metal): a single light wave rolling across
/// the housing from the glow origin, once, at session start.
@available(macOS 14.0, *)
struct IslandRippleModifier: ViewModifier {
    /// How long one burst runs; elapsed time animates 0 → duration.
    static let duration: TimeInterval = 1.2

    let origin: CGPoint
    let elapsedTime: TimeInterval
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.layerEffect(
            ShaderLibrary.ripple(
                .float2(origin),
                .float(elapsedTime),
                .float(3),      // amplitude, points of displacement
                .float(6),      // frequency
                .float(6),      // decay
                .float(1200)    // speed, pt/s
            ),
            maxSampleOffset: CGSize(width: 4, height: 4),
            isEnabled: isEnabled && elapsedTime > 0 && elapsedTime < Self.duration
        )
    }
}

// MARK: - Particle cloud (Metal compute)

/// Motes chasing the beam's sweeping origin while listening, rendered by a
/// Metal compute pipeline (ParticleCloud.metal) into a transparent MTKView.
struct IslandParticleCloudView: View {
    @ObservedObject var state: OverlayState
    let palette: IslandGlowPalette
    let cornerRadius: CGFloat
    let topFilletRadius: CGFloat

    @State private var sweepStart = Date()

    var body: some View {
        GeometryReader { proxy in
            let listening = state.isRecording
            TimelineView(.animation(paused: !listening)) { context in
                let size = proxy.size
                let alive = state.isAudioAlive
                let elapsed = context.date.timeIntervalSince(sweepStart)
                let progress = Float(min(1.0, max(0.0, elapsed / IslandEdgeGlowView.rampDuration)))
                let target = IslandGlowSilhouetteShape.point(
                    atArcFraction: IslandEdgeGlowView.sweepFraction(at: elapsed),
                    cornerRadius: cornerRadius,
                    topFilletRadius: topFilletRadius,
                    inset: 0,
                    in: size
                )
                let center = CGPoint(
                    x: target.x / max(size.width, 1),
                    y: target.y / max(size.height, 1)
                )
                ParticleCloudSurface(
                    progress: (listening && alive) ? progress : 0,
                    center: center,
                    palette: palette
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: state.sessionEpoch) { _ in
            sweepStart = Date()
        }
    }
}

/// Hosts the MTKView running the compute pipeline.
private struct ParticleCloudSurface: NSViewRepresentable {
    let progress: Float
    let center: CGPoint
    let palette: IslandGlowPalette

    func makeCoordinator() -> ParticleRenderer {
        ParticleRenderer()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        // The compute pipeline writes straight into the drawable.
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        // macOS: transparency lives on the backing CAMetalLayer.
        view.layer?.isOpaque = false
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        push(to: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        push(to: view, coordinator: context.coordinator)
    }

    /// At ramp zero the render loop stops entirely; one forced draw first so
    /// the last visible frame is a cleared one, not frozen motes.
    private func push(to view: MTKView, coordinator: ParticleRenderer) {
        coordinator.progress = progress
        coordinator.center = center
        coordinator.applyPalette(palette)
        if progress == 0 {
            if !view.isPaused {
                view.isPaused = true
                view.draw()
            }
        } else {
            view.isPaused = false
        }
    }
}

/// Owns the Metal state and drives one compute pass per frame: clear the
/// drawable, then move and draw every particle.
final class ParticleRenderer: NSObject {
    /// Mirrors `Particle` in ParticleCloud.metal member-for-member —
    /// reordering members breaks the buffer silently.
    struct Particle {
        var color: SIMD4<Float>
        var radius: Float
        var lifespan: Float
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
    }

    /// Mirrors `ParticleCloudInfo` in ParticleCloud.metal.
    struct CloudInfo {
        var center: SIMD2<Float>
        var progress: Float
    }

    static let particleCount = 32

    var progress: Float = 0
    var center = CGPoint(x: 0.5, y: 0.5)
    private var appliedPalette = IslandGlowPalette.spectrum

    let device: MTLDevice?
    private let pipeline: Pipeline?

    private struct Pipeline {
        let commandQueue: MTLCommandQueue
        let cleanState: MTLComputePipelineState
        let drawState: MTLComputePipelineState
        let particleBuffer: MTLBuffer
    }

    /// Built once for the process: compiling the two compute kernels costs
    /// real milliseconds, and only one island exists at a time.
    private static let sharedDevice = MTLCreateSystemDefaultDevice()
    private static let sharedPipeline: Pipeline? = sharedDevice.flatMap { makePipeline(device: $0) }

    override init() {
        device = Self.sharedDevice
        pipeline = Self.sharedPipeline
        super.init()
    }

    /// Fail soft: a missing pipeline draws nothing instead of crashing a
    /// menu-bar app over a decorative effect.
    private static func makePipeline(device: MTLDevice) -> Pipeline? {
        guard
            let commandQueue = device.makeCommandQueue(),
            let library = try? device.makeDefaultLibrary(bundle: .main),
            let cleanFunction = library.makeFunction(name: "cleanScreen"),
            let drawFunction = library.makeFunction(name: "drawParticles"),
            let cleanState = try? device.makeComputePipelineState(function: cleanFunction),
            let drawState = try? device.makeComputePipelineState(function: drawFunction)
        else {
            return nil
        }

        // Zeroed positions make the kernel's respawn branch scatter the
        // cloud on its first frame.
        let colors = IslandGlowPalette.spectrum.particleColors
        let particles = (0..<particleCount).map { index in
            Particle(
                color: colors[index % colors.count],
                radius: Float.random(in: 3..<12),
                lifespan: 0,
                position: .zero,
                velocity: SIMD2(Float.random(in: 2..<4), Float.random(in: 2..<4))
            )
        }
        guard let particleBuffer = device.makeBuffer(
            bytes: particles,
            length: MemoryLayout<Particle>.stride * particleCount
        ) else {
            return nil
        }

        return Pipeline(
            commandQueue: commandQueue,
            cleanState: cleanState,
            drawState: drawState,
            particleBuffer: particleBuffer
        )
    }

    /// Recolors the live buffer when the palette pick changes.
    func applyPalette(_ palette: IslandGlowPalette) {
        guard palette != appliedPalette, let pipeline else { return }
        appliedPalette = palette

        let colors = palette.particleColors
        let particles = pipeline.particleBuffer.contents()
            .bindMemory(to: Particle.self, capacity: Self.particleCount)
        for index in 0..<Self.particleCount {
            particles[index].color = colors[index % colors.count]
        }
    }
}

extension ParticleRenderer: MTKViewDelegate {
    func draw(in view: MTKView) {
        guard
            let pipeline,
            let drawable = view.currentDrawable,
            let commandBuffer = pipeline.commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return
        }

        let texture = drawable.texture
        encoder.setTexture(texture, index: 0)

        encoder.setComputePipelineState(pipeline.cleanState)
        let width = pipeline.cleanState.threadExecutionWidth
        let height = pipeline.cleanState.maxTotalThreadsPerThreadgroup / width
        encoder.dispatchThreads(
            MTLSize(width: texture.width, height: texture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )

        encoder.setComputePipelineState(pipeline.drawState)
        encoder.setBuffer(pipeline.particleBuffer, offset: 0, index: 0)
        var info = CloudInfo(
            center: SIMD2(Float(center.x), Float(center.y)),
            progress: progress
        )
        encoder.setBytes(&info, length: MemoryLayout<CloudInfo>.stride, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: Self.particleCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: pipeline.drawState.threadExecutionWidth,
                height: 1,
                depth: 1
            )
        )

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

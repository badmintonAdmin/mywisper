//
//  StatusHUD.swift
//  mywisper
//
//  A small, always-visible floating toast HUD. Used to surface brief feedback (AI on/off,
//  cycled AI mode, standalone status messages) regardless of which app is focused — including
//  when mywisper's own windows are open. Non-activating, single shared instance, auto-dismissing.
//

import SwiftUI
import AppKit

/// Observable model backing the HUD's SwiftUI view.
final class StatusHUDState: ObservableObject {
    @Published var text: String = ""
    @Published var systemImage: String? = nil
    @Published var visible: Bool = false
}

/// A compact floating capsule toast. Call `StatusHUD.shared.show(_:systemImage:)` from the main
/// thread. The single instance is reused; a new message resets the auto-hide timer.
final class StatusHUD {
    static let shared = StatusHUD()

    private let panel: ToastPanel
    private let state = StatusHUDState()
    private var hideTimer: Timer?

    private init() {
        panel = ToastPanel(state: state)
    }

    /// Show a short message (with an optional SF Symbol) for ~1.3s, then fade out. Resets the
    /// timer if called again before the previous message dismisses. Must be called on main.
    func show(_ text: String, systemImage: String? = nil, duration: TimeInterval = 1.3) {
        state.text = text
        state.systemImage = systemImage

        panel.layoutForContent()
        panel.positionTopCenter()
        panel.orderFrontRegardless()

        // Fade in.
        withAnimation(.easeOut(duration: 0.15)) {
            state.visible = true
        }

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func dismiss() {
        withAnimation(.easeIn(duration: 0.2)) {
            state.visible = false
        }
        // Order the panel out after the fade completes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self, !self.state.visible else { return }
            self.panel.orderOut(nil)
        }
    }
}

/// Borderless, non-activating NSPanel that hosts the toast view. Floats above normal windows and
/// joins all spaces / full-screen apps so it shows no matter what is focused.
final class ToastPanel: NSPanel {
    private let hostingView: NSHostingView<StatusHUDView>

    init(state: StatusHUDState) {
        hostingView = NSHostingView(rootView: StatusHUDView(state: state))

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        self.level = .statusBar
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = false
        self.isMovable = false
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.ignoresMouseEvents = true // Purely informational — never steal clicks.
        self.hidesOnDeactivate = false
        self.animationBehavior = .none

        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        self.contentView = hostingView
    }

    /// Resize the panel to fit the current content (the SwiftUI view uses .fixedSize()).
    func layoutForContent() {
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        let width = max(size.width, 120)
        let height = max(size.height, 32)
        self.setContentSize(NSSize(width: width, height: height))
    }

    /// Position near the top-center of the main screen (just below the menu bar).
    func positionTopCenter() {
        guard let screen = NSScreen.main else { return }
        let x = screen.frame.midX - frame.width / 2
        let y = screen.frame.maxY - frame.height - 48
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// The visual toast: a rounded dark capsule with optional SF Symbol + text. Compact and clean,
/// in the same spirit as the recording pill but independent.
struct StatusHUDView: View {
    @ObservedObject var state: StatusHUDState

    var body: some View {
        HStack(spacing: 7) {
            if let symbol = state.systemImage {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }
            Text(state.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            ZStack {
                Capsule()
                    .fill(Color(white: 0.1).opacity(0.92))
                Capsule()
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            }
        )
        .fixedSize()
        .opacity(state.visible ? 1 : 0)
        .scaleEffect(state.visible ? 1 : 0.96)
    }
}

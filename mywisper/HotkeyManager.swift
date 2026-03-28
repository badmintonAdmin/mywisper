//
//  HotkeyManager.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import Cocoa

class HotkeyManager {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastFnReleaseTime: Date?
    private var fnIsDown = false

    // CGEvent tap for truly global hotkey
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var doubleTapInterval: TimeInterval = 0.4

    // Custom hotkey settings
    var customHotkeyKeyCode: UInt16 = 49 // Space
    var customHotkeyModifiers: NSEvent.ModifierFlags = [.control, .option]
    var useCustomHotkey: Bool = false

    // AI toggle hotkey settings
    var aiToggleHotkeyKeyCode: UInt16 = 0 // A
    var aiToggleHotkeyModifiers: NSEvent.ModifierFlags = [.control, .option]
    var useAIToggleHotkey: Bool = false

    // Cancel hotkey settings
    var cancelHotkeyKeyCode: UInt16 = 53 // Escape

    /// Set to true while recording/transcribing so cancel key is intercepted
    var isOperationActive = false

    var onToggle: (() -> Void)?
    var onToggleAI: (() -> Void)?
    var onCancel: (() -> Void)?

    func register() {
        unregister()

        // Always register CGEvent tap — needed for ESC cancel,
        // and also handles custom hotkeys when enabled
        registerCGEventTap()

        // Fn double-tap via NSEvent monitors
        registerFnDoubleTap()
    }

    // MARK: - CGEvent Tap (global hotkey that works everywhere)

    private func registerCGEventTap() {
        let eventMask = (1 << CGEventType.keyDown.rawValue)

        // Store self in a pointer so the C callback can access it
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    // Re-enable the tap if it gets disabled
                    if let tap = manager.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard type == .keyDown else { return Unmanaged.passUnretained(event) }

                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags

                // Check if this matches our custom recording hotkey
                if manager.useCustomHotkey && keyCode == manager.customHotkeyKeyCode {
                    if manager.matchesModifiers(flags, required: manager.customHotkeyModifiers) {
                        DispatchQueue.main.async {
                            manager.onToggle?()
                        }
                        return nil // consume the event
                    }
                }

                // Check if this matches our AI toggle hotkey
                if manager.useAIToggleHotkey && keyCode == manager.aiToggleHotkeyKeyCode {
                    if manager.matchesModifiers(flags, required: manager.aiToggleHotkeyModifiers) {
                        DispatchQueue.main.async {
                            manager.onToggleAI?()
                        }
                        return nil // consume the event
                    }
                }

                // Cancel hotkey cancels current operation when active
                if keyCode == manager.cancelHotkeyKeyCode && manager.isOperationActive {
                    DispatchQueue.main.async {
                        manager.onCancel?()
                    }
                    return nil // consume the event
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        )

        guard let eventTap = eventTap else {
            print("mywisper: ERROR - Failed to create CGEvent tap. Make sure Accessibility permission is granted.")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func matchesModifiers(_ flags: CGEventFlags, required: NSEvent.ModifierFlags) -> Bool {
        if required.contains(.control) != flags.contains(.maskControl) { return false }
        if required.contains(.option) != flags.contains(.maskAlternate) { return false }
        if required.contains(.shift) != flags.contains(.maskShift) { return false }
        if required.contains(.command) != flags.contains(.maskCommand) { return false }
        return true
    }

    // MARK: - Fn Double-tap

    private func registerFnDoubleTap() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == 63 else { return }

        let fnPressed = event.modifierFlags.contains(.function)

        if fnPressed && !fnIsDown {
            fnIsDown = true
        } else if !fnPressed && fnIsDown {
            fnIsDown = false

            let now = Date()
            if let lastRelease = lastFnReleaseTime,
               now.timeIntervalSince(lastRelease) < doubleTapInterval {
                lastFnReleaseTime = nil
                DispatchQueue.main.async { [weak self] in
                    self?.onToggle?()
                }
            } else {
                lastFnReleaseTime = now
            }
        }
    }

    // MARK: - Cleanup

    func unregister() {
        unregisterFnOnly()
        unregisterCGEventTap()
    }

    func unregisterFnOnly() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private func unregisterCGEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    deinit {
        unregister()
    }

    // MARK: - Hotkey display helpers

    static func modifiersString(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        return parts.joined()
    }

    static func keyCodeToString(_ keyCode: UInt16) -> String {
        let mapping: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
            43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
            53: "Escape", 76: "Enter",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
            97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12",
        ]
        return mapping[keyCode] ?? "Key\(keyCode)"
    }

    static func hotkeyDisplayString(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> String {
        return modifiersString(modifiers) + keyCodeToString(keyCode)
    }
}

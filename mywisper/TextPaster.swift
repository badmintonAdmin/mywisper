//
//  TextPaster.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import Cocoa

class TextPaster {
    func paste(text: String, previousApp: NSRunningApplication?) {
        // Put text on clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Re-activate the app that was focused before recording started
        if let app = previousApp {
            app.activate(options: .activateIgnoringOtherApps)
        }

        // Only simulate Cmd+V if accessibility is granted
        guard AXIsProcessTrusted() else {
            return
        }

        // Wait for the target app to become active, then simulate Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let source = CGEventSource(stateID: .combinedSessionState)

            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            keyDown?.flags = .maskCommand

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyUp?.flags = .maskCommand

            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    static func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}

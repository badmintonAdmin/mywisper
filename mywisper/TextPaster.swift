//
//  TextPaster.swift
//  mywisper
//
//  Created by Сергей Борисов on 12.03.2026.
//

import Cocoa

class TextPaster {
    /// Outcome of a `paste(...)` call so the caller can tell the user whether the text was
    /// actually pasted or merely placed on the clipboard.
    enum PasteResult {
        /// Text was copied AND Cmd+V was simulated into the focused field.
        case pasted
        /// Text was copied to the clipboard only (Accessibility not granted, no auto-paste).
        case copiedToClipboardOnly
    }

    /// Snapshot of the clipboard contents taken right before the most recent paste, so
    /// `undoLastPaste()` can restore it. nil means there is nothing to undo.
    private(set) var lastClipboardBeforePaste: String?
    /// The text we most recently pasted (used to confirm there is something to undo).
    private(set) var lastPastedText: String?

    @discardableResult
    func paste(text: String, previousApp: NSRunningApplication?) -> PasteResult {
        // Put text on clipboard
        let pasteboard = NSPasteboard.general
        // Remember the previous clipboard so the user can undo this paste.
        lastClipboardBeforePaste = pasteboard.string(forType: .string) ?? ""
        lastPastedText = text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Re-activate the app that was focused before recording started
        if let app = previousApp {
            app.activate(options: .activateIgnoringOtherApps)
        }

        // Only simulate Cmd+V if accessibility is granted
        guard AXIsProcessTrusted() else {
            return .copiedToClipboardOnly
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

        return .pasted
    }

    /// Outcome of an `undoLastPaste()` call.
    enum UndoResult {
        /// Nothing to undo (no prior paste recorded this session).
        case nothingToUndo
        /// Previous clipboard restored AND Cmd+Z simulated to remove the pasted text.
        case undone
        /// Previous clipboard restored only (Accessibility not granted, couldn't simulate Cmd+Z).
        case clipboardRestoredOnly
    }

    /// Best-effort undo of the most recent auto-paste: restore the clipboard contents that were
    /// present before the paste, and (when Accessibility is granted) simulate Cmd+Z into the
    /// focused app to remove the just-pasted text. No-op if there's nothing to undo.
    @discardableResult
    func undoLastPaste() -> UndoResult {
        guard lastPastedText != nil, let previous = lastClipboardBeforePaste else {
            return .nothingToUndo
        }

        // Restore the prior clipboard contents.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !previous.isEmpty {
            pasteboard.setString(previous, forType: .string)
        }

        // Consume the undo state so a second invocation is a safe no-op.
        lastPastedText = nil
        lastClipboardBeforePaste = nil

        guard AXIsProcessTrusted() else {
            return .clipboardRestoredOnly
        }

        // Simulate Cmd+Z into the focused app to remove the pasted text.
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x06, keyDown: true) // 0x06 = Z
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x06, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        return .undone
    }

    static func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}

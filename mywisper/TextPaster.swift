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
        let pasteboard = NSPasteboard.general
        // Snapshot the user's current clipboard BEFORE we overwrite it. This serves two purposes:
        //  1) on a successful auto-paste we restore it so the user's clipboard is left untouched;
        //  2) it backs the "undo last paste" feature.
        let previousClipboard = pasteboard.string(forType: .string) ?? ""

        // Put the transcription on the clipboard so Cmd+V can pick it up.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Re-activate the app that was focused before recording started
        if let app = previousApp {
            app.activate(options: .activateIgnoringOtherApps)
        }

        // We can only auto-paste when Accessibility is granted AND there's an app to paste into.
        // Otherwise leave the transcription on the clipboard as the fallback (copy-only) and
        // record the undo bookkeeping accordingly.
        guard AXIsProcessTrusted(), previousApp != nil else {
            lastClipboardBeforePaste = previousClipboard
            lastPastedText = text
            return .copiedToClipboardOnly
        }

        // Auto-paste path. NOTE: we can't 100% detect that the keystroke actually landed in a
        // text field (the focused control may be non-editable, or the app may swallow Cmd+V), so
        // this is best-effort. We assume the paste landed and restore the user's clipboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let source = CGEventSource(stateID: .combinedSessionState)

            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            keyDown?.flags = .maskCommand

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyUp?.flags = .maskCommand

            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)

            // After the Cmd+V keystroke has been consumed by the target app (~0.1s later), restore
            // the user's original clipboard so dictation doesn't clobber what they had copied.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                pasteboard.clearContents()
                if !previousClipboard.isEmpty {
                    pasteboard.setString(previousClipboard, forType: .string)
                }
            }
        }

        // Undo bookkeeping: since the clipboard is restored to `previousClipboard` after a
        // successful paste, undoLastPaste() doesn't need to touch the clipboard itself — there's
        // nothing left to restore. We record an empty `lastClipboardBeforePaste` to mean "the
        // clipboard is already in the right state, just simulate Cmd+Z".
        lastClipboardBeforePaste = ""
        lastPastedText = text

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

    /// Best-effort undo of the most recent paste: simulate Cmd+Z to remove the just-pasted text,
    /// and make sure the clipboard ends up holding the user's original contents (not the
    /// transcription). No-op if there's nothing to undo.
    ///
    /// Two cases, depending on how the last `paste(...)` resolved:
    ///  - `.pasted`: the clipboard was already restored to the user's original contents right after
    ///    the paste, so `lastClipboardBeforePaste` is "" and the restore below is a no-op (correct).
    ///  - `.copiedToClipboardOnly`: the transcription is still sitting on the clipboard, and
    ///    `lastClipboardBeforePaste` holds the user's original contents, so we restore them here.
    @discardableResult
    func undoLastPaste() -> UndoResult {
        guard lastPastedText != nil, let previous = lastClipboardBeforePaste else {
            return .nothingToUndo
        }

        // Restore the prior clipboard contents (no-op when already restored after a paste).
        let pasteboard = NSPasteboard.general
        let currentClipboard = pasteboard.string(forType: .string) ?? ""
        // Only rewrite the clipboard if it still holds something other than the user's original
        // contents (i.e. the copy-only fallback where the transcription is still on the clipboard).
        if currentClipboard != previous {
            pasteboard.clearContents()
            if !previous.isEmpty {
                pasteboard.setString(previous, forType: .string)
            }
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

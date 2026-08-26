//
//  ActivityAssertion.swift
//  mywisper
//
//  Keeps macOS from App-Napping mywisper while a session is running (ported
//  from Talkify). The app is LSUIElement with no window — exactly the shape
//  App Nap targets. After hours idle the process is throttled and the first
//  session glitches: TimelineView animation clocks slow down, timers stall.
//
//  Held only for the length of a dictation session (record → paste), never
//  while idle — an assertion held all day would trade a rare glitch for a
//  permanent battery cost, which is the wrong way round.
//

import Foundation

final class ActivityAssertion {
    private let reason: String
    private var token: NSObjectProtocol?

    init(reason: String) {
        self.reason = reason
    }

    var isHeld: Bool { token != nil }

    /// Idempotent: a second begin would strand the first token, and a stranded
    /// token is an assertion nothing can ever release.
    func hold() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: reason)
    }

    func release() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}

//
//  NotificationManager.swift
//  mywisper
//
//  Created by Сергей Борисов on 06.05.2026.
//

import Foundation
import UserNotifications

extension Notification.Name {
    static let retryPendingRequested = Notification.Name("mywisper.retryPendingRequested")
}

/// Wraps `UNUserNotificationCenter` to surface failed cloud transcriptions to the user
/// with an inline "Retry" action.
class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private let categoryID = "TRANSCRIPTION_FAILED"
    private let retryActionID = "RETRY"
    private let pendingIDKey = "pendingID"

    private var didConfigure = false

    func configure() {
        guard !didConfigure else { return }
        didConfigure = true

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let retry = UNNotificationAction(
            identifier: retryActionID,
            title: "Retry",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [retry],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error = error {
                print("mywisper: notification auth failed: \(error.localizedDescription)")
            }
        }
    }

    func notifyTranscriptionFailed(pending: PendingRecording, error: Error) {
        let content = UNMutableNotificationContent()
        content.title = "Transcription failed"
        content.body = "Audio saved (\(formatDuration(pending.durationSeconds))) — tap Retry to try again."
        content.sound = .default
        content.categoryIdentifier = categoryID
        content.userInfo = [pendingIDKey: pending.id.uuidString]

        let request = UNNotificationRequest(
            identifier: "transcription-failed-\(pending.id.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("mywisper: failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == retryActionID
                || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        else { return }
        guard let idStr = response.notification.request.content.userInfo[pendingIDKey] as? String,
              let id = UUID(uuidString: idStr) else { return }
        NotificationCenter.default.post(
            name: .retryPendingRequested,
            object: nil,
            userInfo: ["id": id]
        )
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

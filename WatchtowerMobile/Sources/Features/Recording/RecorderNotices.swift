import os
import UserNotifications

/// The recorder's notices as local notifications: the cap notice (the
/// screen is usually locked 2 h 55 m into a recording) and the long-pause
/// auto-finish. Never asks for permission (the link flow does); without it
/// the notice shows in the recorder only.
enum RecorderNotices {
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "RecorderNotices")

    static func postCapNotice() {
        post(
            id: "recording-cap-notice",
            title: "Recording stops in 5 minutes",
            body: "Recordings stop at 3 hours. It is saved and sent to your Mac."
        )
    }

    /// A capture paused for 60 minutes was finished and saved by itself.
    static func postAutoFinishNotice() {
        post(
            id: "recording-auto-finish-notice",
            title: "Recording saved",
            body: "It was paused for 60 minutes, so it was finished automatically and sent to your Mac."
        )
    }

    /// A capture paused for 60 minutes could not be saved when it was
    /// finished automatically: the owner learns of it away from the app.
    static func postAutoFinishFailedNotice() {
        post(
            id: "recording-auto-finish-failed-notice",
            title: "Recording could not be saved",
            body: "Open Watchtower to see what happened to it."
        )
    }

    private static func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.warning("recorder notice \(id, privacy: .public) not posted: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

import os
import UserNotifications

/// The cap notice as a local notification: the screen is usually locked
/// 2 h 55 m into a recording. Never asks for permission (the link flow
/// does); without it the notice shows in the recorder only.
enum RecorderNotices {
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "RecorderNotices")

    static func postCapNotice() {
        let content = UNMutableNotificationContent()
        content.title = "Recording stops in 5 minutes"
        content.body = "Recordings stop at 3 hours. It is saved and sent to your Mac."
        let request = UNNotificationRequest(identifier: "recording-cap-notice", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.warning("cap notice not posted: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

import Foundation
import UserNotifications

/// FNV-1a hash for stable, collision-resistant notification identifiers.
private func fnv1aHash(_ string: String) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return hash
}

final class NotificationService: Sendable {
    static let shared = NotificationService()

    // MARK: - Meeting notification categories

    static let meetingReminderCategoryID = "meeting_reminder"
    static let meetingStopCategoryID = "meeting_stop_recording"
    static let joinActionID = "meeting_join"
    static let joinRecordActionID = "meeting_join_record"
    static let stopRecordingActionID = "meeting_stop_recording_action"

    /// Registers the meeting notification action categories. Called once at
    /// app launch, next to the delegate installation in `WatchtowerApp.init`
    /// (`setNotificationCategories` replaces the whole set — these are the
    /// only categories the app uses).
    static func registerMeetingCategories() {
        let join = UNNotificationAction(identifier: joinActionID, title: "Join", options: [.foreground])
        let joinRecord = UNNotificationAction(identifier: joinRecordActionID, title: "Join + Record", options: [.foreground])
        let reminder = UNNotificationCategory(
            identifier: meetingReminderCategoryID,
            actions: [join, joinRecord],
            intentIdentifiers: []
        )
        let stopAction = UNNotificationAction(identifier: stopRecordingActionID, title: "Stop recording", options: [])
        let stopCategory = UNNotificationCategory(
            identifier: meetingStopCategoryID,
            actions: [stopAction],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([reminder, stopCategory])
    }

    func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func sendDecisionNotification(decision: Decision, channelName: String, digestID: Int) {
        let content = UNMutableNotificationContent()
        content.title = "New decision in #\(channelName)"
        content.body = decision.text
        content.sound = .default
        content.userInfo = ["digestId": digestID, "type": "decision"]

        // Stable identifier using digestID + FNV-1a hash of text (collision-resistant).
        let stableHash = fnv1aHash(decision.text)
        let request = UNNotificationRequest(
            identifier: "decision-\(digestID)-\(stableHash)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func sendTrackUpdateNotification(text: String, channelName: String, itemID: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Update on track"
        content.body = "#\(channelName): \(String(text.prefix(200)))"
        content.sound = .default
        content.userInfo = ["type": "track_update", "trackId": itemID]

        let request = UNNotificationRequest(
            identifier: "track-update-\(itemID)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func sendTrackNotification(text: String, channelName: String, priority: String) {
        let content = UNMutableNotificationContent()
        let prefix = priority == "high" ? "Urgent: " : ""
        content.title = "\(prefix)New track in #\(channelName)"
        content.body = String(text.prefix(200))
        content.sound = .default
        content.userInfo = ["type": "track"]

        let stableHash = fnv1aHash(text)
        let request = UNNotificationRequest(
            identifier: "track-\(stableHash)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Watchtower"
        content.body = "Notifications are working!"
        content.sound = .default
        content.userInfo = ["type": "test"]

        let request = UNNotificationRequest(
            identifier: "test-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func sendBriefingNotification(attentionCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Morning Briefing Ready"
        content.body = attentionCount > 0
            ? "\(attentionCount) items need attention"
            : "Your daily briefing is ready"
        content.sound = .default
        content.userInfo = ["type": "briefing"]

        let request = UNNotificationRequest(
            identifier: "briefing-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func sendBoardConfigChangedNotification(boardName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Board configuration changed"
        content.body = "\(boardName) — consider re-analyzing"
        content.sound = .default
        content.userInfo = ["type": "board_config_changed"]

        let stableHash = fnv1aHash(boardName)
        let request = UNNotificationRequest(
            identifier: "board-config-\(stableHash)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func sendDailySummaryNotification(summary: String) {
        let content = UNMutableNotificationContent()
        content.title = "Daily summary ready"
        content.body = String(summary.prefix(200))
        content.sound = .default
        content.userInfo = ["type": "daily_summary"]

        let request = UNNotificationRequest(
            identifier: "daily-summary-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func sendTargetExtractReadyNotification(count: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Target draft ready"
        content.body = count == 1
            ? "1 target extracted — tap to review"
            : "\(count) targets extracted — tap to review"
        content.sound = .default
        content.userInfo = ["type": "target_extract"]

        let request = UNNotificationRequest(
            identifier: "target-extract-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func sendTargetExtractFailedNotification(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "Target extraction failed"
        content.body = String(reason.prefix(200))
        content.sound = .default
        content.userInfo = ["type": "target_extract"]

        let request = UNNotificationRequest(
            identifier: "target-extract-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func sendTranscriptReadyNotification(title: String) {
        sendTranscriptNotification(title: "Transcript ready", body: title, hashInput: title)
    }

    func sendTranscriptFailedNotification(reason: String) {
        sendTranscriptNotification(title: "Transcription failed", body: reason, hashInput: reason)
    }

    /// Pre-meeting reminder. With a conference link the push carries the
    /// Join / Join + Record action category; without one it is plain. The
    /// dedup key (event id + start time) makes the identifier stable, so a
    /// re-poll can never double-post the same reminder.
    func sendMeetingReminderNotification(eventID: String, title: String, body: String, conferenceURL: String, dedupKey: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [
            "type": "meeting_reminder",
            "eventId": eventID,
            "eventTitle": title,
            "conferenceUrl": conferenceURL,
        ]
        if !conferenceURL.isEmpty {
            content.categoryIdentifier = Self.meetingReminderCategoryID
        }
        let request = UNNotificationRequest(
            identifier: "meeting-reminder-\(fnv1aHash(dedupKey))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// "Meeting ended — still recording" push with a Stop-recording action.
    /// The dedup key embeds the 10-minute repeat-window index, so each window
    /// posts a fresh notification.
    func sendStopRecordingNotification(eventID: String, title: String, dedupKey: String) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting ended — still recording"
        content.body = title
        content.sound = .default
        content.userInfo = ["type": "meeting_stop_recording", "eventId": eventID]
        content.categoryIdentifier = Self.meetingStopCategoryID
        let request = UNNotificationRequest(
            identifier: "meeting-stop-\(fnv1aHash(dedupKey))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func sendTranscriptNotification(title: String, body: String, hashInput: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(200))
        content.sound = .default
        content.userInfo = ["type": "meeting_transcript"]

        let stableHash = fnv1aHash(hashInput)
        let request = UNNotificationRequest(
            identifier: "meeting-transcript-\(stableHash)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

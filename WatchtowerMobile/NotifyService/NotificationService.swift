import UserNotifications

/// Notification Service Extension (mobile POC spec §2.1). The ask alert's
/// content is filled in by Task 13; until then every notification is
/// delivered exactly as it arrived.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        contentHandler(request.content)
    }
}

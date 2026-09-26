import Foundation

/// Abstraction over the two target-extraction completion notifications, so
/// `TargetExtractCenter` can be unit-tested without touching the real
/// `UNUserNotificationCenter` (which has no app-bundle context under
/// `swift test` and crashes if invoked there).
protocol TargetExtractNotifying {
    func sendTargetExtractReadyNotification(count: Int)
    func sendTargetExtractFailedNotification(reason: String)
}

extension NotificationService: TargetExtractNotifying {}

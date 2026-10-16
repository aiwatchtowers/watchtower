import Foundation

/// App-wide notification switches from Settings → Features → Notifications.
/// The two renamed switches keep their pre-rename `@AppStorage` keys, so a
/// value the owner saved under the old label carries over.
package enum NotificationPreferences {
    /// "Pause notifications" (was "Enable quiet hours"); absent = off.
    package static let pausedKey = "quietHoursEnabled"
    /// "Briefing notifications" (was the dead "Daily summary notifications"); absent = on.
    package static let briefingKey = "notifyDailySummary"

    package static func isPaused(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: pausedKey)
    }

    package static func briefingEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: briefingKey) as? Bool ?? true
    }
}

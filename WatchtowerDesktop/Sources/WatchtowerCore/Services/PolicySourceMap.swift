import Foundation

/// Which organization-policy source (#608, `AllowedSources`) an account kind
/// belongs to, keyed on `ConnectionService`'s raw values and a few aliases:
/// Google covers Gmail and Google Calendar, Email covers IMAP and Outlook,
/// the Calendar service (CalDAV and ICS feeds) is `caldav`, Jira covers
/// Confluence. Go's guard keys on its command groups instead
/// (`cmd/accounts.go`), where `calendar` is Google Calendar.
package enum PolicySourceMap {
    /// nil for a kind no source decides (Quick Connections).
    package static func policySource(forAccountKind kind: String) -> String? {
        switch kind.lowercased() {
        case "slack": "slack"
        case "google", "gmail", "googlecalendar", "google_calendar": "google"
        case "email", "imap", "outlook": "imap"
        case "calendar", "caldav", "ics": "caldav"
        case "jira", "confluence": "jira"
        case "linear": "linear"
        default: nil
        }
    }

    /// Whether `policy` lets the account kind be connected and synced.
    package static func allowed(_ kind: String, policy: ManagedPolicy) -> Bool {
        policySource(forAccountKind: kind).map(policy.sourceAllowed) ?? true
    }
}

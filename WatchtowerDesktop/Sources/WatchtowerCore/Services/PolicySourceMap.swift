import Foundation

/// Which organization-policy source (#608, `AllowedSources`) an account kind
/// belongs to: Google covers Gmail and Calendar, Email covers IMAP and
/// Outlook, Jira covers Confluence. Go's command groups map the same way
/// (`cmd/accounts.go`).
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

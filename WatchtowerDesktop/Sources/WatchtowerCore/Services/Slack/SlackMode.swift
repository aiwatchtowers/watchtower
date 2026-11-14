import Foundation

/// The app's Slack mode. Twin of Go `slackmode.Derive`, both checked over
/// `internal/slackmode/testdata/slack_mode_cases.json` (SLACKMODE-01).
package enum SlackMode: String {
    case full, live, off

    /// Full when a synced Slack account exists, else Live when any probe
    /// status is `ok`, else Off.
    package static func derive(full: Bool, liveStatuses: [String]) -> Self {
        if full { return .full }
        return liveStatuses.contains("ok") ? .live : .off
    }
}

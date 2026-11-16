import Foundation

/// Statistics → Channels: the Stop syncing strings and a row's sync state
/// (adaptive Slack sync, #1709). The mockups in
/// `docs/design/mockups/slack-adaptive-sync/` show these strings; the Go
/// suggestion reasons (`internal/db/channel_stats.go`) must read the same.
package enum ChannelStatsPresentation {
    /// Where a channel stands with the sync.
    package enum SyncState: Equatable {
        case synced
        /// Stop syncing: no new messages are stored, except mentions.
        case notSynced
        /// Sync again's catch-up of the skipped period is still running;
        /// `since` is its lower bound.
        case catchingUp(since: Date)
    }

    /// A row's state from `channel_settings.sync_excluded` and
    /// `catchup_from` (unix seconds, nil = no catch-up pending).
    package static func syncState(isSyncExcluded: Bool, catchupFrom: Double?) -> SyncState {
        if isSyncExcluded { return .notSynced }
        if let catchupFrom { return .catchingUp(since: Date(timeIntervalSince1970: catchupFrom)) }
        return .synced
    }

    // MARK: Row actions

    package static let stopSyncing = "Stop syncing"
    package static let syncAgain = "Sync again"
    package static let stopSyncingHelp = "Stop storing new messages from this channel. Mentions of you still arrive."
    package static let syncAgainHelp = "Sync this channel again and fetch what was missed while it was not synced."
    package static let notSyncedTag = "Not synced"
    package static let catchingUpTag = "Catching up"

    /// The catch-up's caption, its start as "Nov 2".
    package static func catchingUpCaption(since date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d"
        return "Fetching messages since \(formatter.string(from: date)), a little each sync."
    }

    /// The error a failed Stop syncing / Sync again shows; the row stays as
    /// it was.
    package static func actionFailed(excluding: Bool, _ detail: String) -> String {
        "\(excluding ? "Stop syncing" : "Sync again") failed: \(detail)"
    }

    // MARK: Suggestions

    package static let suggestionTitle = "Suggest Stop syncing"
    package static let reasonMuted = "muted 30+ days, no messages or mentions from you"
    package static func reasonBots(_ percent: Int) -> String { "\(percent)% bot messages, no value signals" }

    // MARK: Filter

    package static let filterNotSynced = "Not synced"
    package static let notSyncedCaption = "Watchtower stores no new messages from these channels, except mentions of you. "
        + "What was stored before stays. Sync again fetches what was missed."
    package static let notSyncedEmpty = "Every channel is synced."
}

import Foundation

/// Design-only string table of the Statistics → Channels changes in the
/// adaptive Slack sync plan (`docs/superpowers/plans/2026-11-15-slack-adaptive-sync.md`,
/// Task 6). The implementation moves these strings into
/// `ChannelStatsPresentation` and pins them there; `SlackAdaptiveSyncMockCopyTests`
/// pins this table so the mockups and the plan cannot drift apart. Sample
/// data only: made-up channel names.
enum SlackAdaptiveSyncMockCopy {
    // MARK: Row actions

    static let stopSyncing = "Stop syncing"
    static let syncAgain = "Sync again"
    static let stopSyncingHelp = "Stop storing new messages from this channel. Mentions of you still arrive."
    static let syncAgainHelp = "Sync this channel again and fetch what was missed while it was not synced."
    static let notSyncedTag = "Not synced"
    static let catchingUpTag = "Catching up"
    static func catchingUpCaption(since: String) -> String {
        "Fetching messages since \(since), a little each sync."
    }

    // MARK: Suggestions

    static let suggestionTitle = "Suggest Stop syncing"
    static let reasonMuted = "muted 30+ days, no messages or mentions from you"
    static func reasonBots(_ percent: Int) -> String { "\(percent)% bot messages, no value signals" }

    // MARK: Filter

    static let filterAll = "All"
    static let filterMuted = "Muted"
    static let filterFavorites = "Favorites"
    static let filterRecommendations = "Recommendations"
    static let filterNotSynced = "Not synced"
    static let notSyncedCaption = "Watchtower stores no new messages from these channels, except mentions of you. "
        + "What was stored before stays. Sync again fetches what was missed."
    static let notSyncedEmpty = "Every channel is synced."
}

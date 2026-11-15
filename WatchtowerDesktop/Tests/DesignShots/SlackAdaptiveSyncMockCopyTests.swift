import XCTest

/// Pins the adaptive Slack sync plan's Statistics strings (Task 6 of
/// `docs/superpowers/plans/2026-11-15-slack-adaptive-sync.md`) so the
/// mockups and the plan cannot drift. The implementation moves them into
/// `ChannelStatsPresentation` and pins them there.
@MainActor
final class SlackAdaptiveSyncMockCopyTests: XCTestCase {
    typealias Copy = SlackAdaptiveSyncMockCopy

    func testRowActions() {
        XCTAssertEqual([Copy.stopSyncing, Copy.syncAgain], ["Stop syncing", "Sync again"])
        XCTAssertTrue(Copy.stopSyncingHelp.contains("Mentions of you still arrive"))
        XCTAssertTrue(Copy.syncAgainHelp.contains("fetch what was missed"))
        XCTAssertEqual(Copy.catchingUpCaption(since: "Nov 2"), "Fetching messages since Nov 2, a little each sync.")
    }

    func testSuggestionReasonsMatchTheRule() {
        XCTAssertEqual(Copy.reasonMuted, "muted 30+ days, no messages or mentions from you")
        XCTAssertEqual(Copy.reasonBots(94), "94% bot messages, no value signals")
    }

    func testFilterCopyNamesWhatStays() {
        XCTAssertEqual([Copy.filterAll, Copy.filterMuted, Copy.filterFavorites, Copy.filterRecommendations, Copy.filterNotSynced],
                       ["All", "Muted", "Favorites", "Recommendations", "Not synced"])
        XCTAssertTrue(Copy.notSyncedCaption.contains("except mentions of you"))
        XCTAssertTrue(Copy.notSyncedCaption.contains("What was stored before stays"))
    }
}

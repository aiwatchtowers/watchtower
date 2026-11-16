import XCTest
@testable import WatchtowerCore

/// Statistics → Channels' Stop syncing copy and row state (#1709); the
/// strings are the mockups' (`docs/design/mockups/slack-adaptive-sync/`).
final class ChannelStatsPresentationTests: XCTestCase {
    typealias Copy = ChannelStatsPresentation

    func testSyncState() {
        XCTAssertEqual(Copy.syncState(isSyncExcluded: false, catchupFrom: nil), .synced)
        XCTAssertEqual(Copy.syncState(isSyncExcluded: true, catchupFrom: nil), .notSynced)
        XCTAssertEqual(Copy.syncState(isSyncExcluded: false, catchupFrom: 1_800_000_000),
                       .catchingUp(since: Date(timeIntervalSince1970: 1_800_000_000)))
        // Stop syncing during a catch-up clears it in the same write; were
        // both set, the exclusion wins.
        XCTAssertEqual(Copy.syncState(isSyncExcluded: true, catchupFrom: 1_800_000_000), .notSynced)
    }

    func testRowActions() throws {
        XCTAssertEqual([Copy.stopSyncing, Copy.syncAgain], ["Stop syncing", "Sync again"])
        XCTAssertEqual(Copy.stopSyncingHelp, "Stop storing new messages from this channel. Mentions of you still arrive.")
        XCTAssertEqual(Copy.syncAgainHelp, "Sync this channel again and fetch what was missed while it was not synced.")
        XCTAssertEqual([Copy.notSyncedTag, Copy.catchingUpTag], ["Not synced", "Catching up"])
        let nov2 = Date(timeIntervalSince1970: 1_793_620_800) // 2026-11-02 12:00 UTC
        XCTAssertEqual(try Copy.catchingUpCaption(since: nov2, timeZone: XCTUnwrap(TimeZone(identifier: "UTC"))),
                       "Fetching messages since Nov 2, a little each sync.")
        XCTAssertEqual(Copy.actionFailed(excluding: true, "no channel"), "Stop syncing failed: no channel")
        XCTAssertEqual(Copy.actionFailed(excluding: false, "no channel"), "Sync again failed: no channel")
    }

    /// The reasons are the Go rule's (`excludeReason`, pinned by
    /// `internal/db/testdata/channel_recommendation_cases.json`).
    func testSuggestionReasonsMatchTheRule() {
        XCTAssertEqual(Copy.suggestionTitle, "Suggest Stop syncing")
        XCTAssertEqual(Copy.reasonMuted, "muted 30+ days, no messages or mentions from you")
        XCTAssertEqual(Copy.reasonBots(94), "94% bot messages, no value signals")
    }

    func testFilterCopyNamesWhatStays() {
        XCTAssertEqual(Copy.filterNotSynced, "Not synced")
        XCTAssertEqual(Copy.notSyncedCaption,
                       "Watchtower stores no new messages from these channels, except mentions of you. "
                       + "What was stored before stays. Sync again fetches what was missed.")
        XCTAssertEqual(Copy.notSyncedEmpty, "Every channel is synced.")
    }
}

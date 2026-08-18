import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

@MainActor
final class SidebarCountsViewModelTests: XCTestCase {

    /// catchUpTotalCount must be the sum of the four Catch-Up source counts:
    /// digests + tracks + inbox + briefings (not targets/recommendations).
    func testCatchUpTotalCountIsSumOfSourceCounts() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        vm.unreadDigestCount = 3
        vm.updatedTrackCount = 5
        vm.inboxPendingCount = 2
        vm.unreadBriefingCount = 4
        // Counts that must NOT contribute to the Catch-Up badge.
        vm.activeTaskCount = 99
        vm.recommendationCount = 7

        XCTAssertEqual(vm.catchUpTotalCount, 3 + 5 + 2 + 4)
    }

    func testCatchUpTotalCountIsZeroWhenNoUnread() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        XCTAssertEqual(vm.catchUpTotalCount, 0)
    }

    /// With an active session, the Catch-Up badge counts its pending themes,
    /// not the raw unread sum.
    func testCatchUpTotalCountIsPendingThemesOfActiveSession() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try await manager.dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO catchup_sessions (id, created_at, status, total_themes, reviewed_count)
                    VALUES (1, '2026-06-20T00:00:00Z', 'active', 4, 1)
                    """
            )
            // 3 pending + 1 reviewed theme; badge must be 3.
            for i in 1...3 {
                try db.execute(
                    sql: """
                        INSERT INTO catchup_themes (session_id, order_idx, title, created_at, updated_at, review_state)
                        VALUES (1, ?, ?, '2026-06-20T00:00:00Z', '2026-06-20T00:00:00Z', 'pending')
                        """,
                    arguments: [i, "Theme \(i)"]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO catchup_themes (session_id, order_idx, title, created_at, updated_at, review_state)
                    VALUES (1, 4, 'Reviewed', '2026-06-20T00:00:00Z', '2026-06-20T00:00:00Z', 'reviewed')
                    """
            )
        }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        // Unread sum would be non-zero too; pending-themes must win.
        vm.unreadDigestCount = 99
        await vm.loadInitial()

        XCTAssertEqual(vm.catchUpTotalCount, 3)
    }

    /// With no active session, the badge falls back to the unread source sum.
    func testCatchUpTotalCountFallsBackToUnreadSumWithNoSession() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()
        vm.unreadDigestCount = 3
        vm.updatedTrackCount = 5
        vm.inboxPendingCount = 2
        vm.unreadBriefingCount = 4

        XCTAssertEqual(vm.catchUpTotalCount, 3 + 5 + 2 + 4)
    }

    /// The Dashboard sidebar badge is the count of open situations — the Feed tab
    /// no longer counts unread inbox items directly (see D9 dashboard task).
    func testSituationsCountReflectsOnlyOpenSituations() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try await manager.dbPool.write { db in
            try TestDatabase.insertSituation(db, status: "open")
            try TestDatabase.insertSituation(db, status: "open")
            try TestDatabase.insertSituation(db, status: "done")
            try TestDatabase.insertSituation(db, status: "snoozed")
        }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.situationsCount, 2)
    }

    func testSituationsCountIsZeroOnEmptyDB() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.situationsCount, 0)
    }

    /// The Ideas badge is the count of ideas awaiting owner review — matches
    /// `IdeaQueries.countForReview` exactly (proposed OR flagged needs_review).
    func testIdeasCountMatchesCountForReview() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try await manager.dbPool.write { db in
            try TestDatabase.insertIdea(db, status: "proposed")
            try TestDatabase.insertIdea(db, status: "active", needsReview: true)
            try TestDatabase.insertIdea(db, status: "active")
            try TestDatabase.insertIdea(db, status: "dropped")
        }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        let expected = try await manager.dbPool.read { try IdeaQueries.countForReview($0) }
        XCTAssertEqual(vm.ideasCount, expected)
        XCTAssertEqual(vm.ideasCount, 2)
    }

    func testIdeasCountIsZeroOnEmptyDB() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.ideasCount, 0)
    }

    /// The Digests sidebar badge sums Slack + stream + decision unread — the
    /// same three sources the Digests screen's tab header shows, not Slack
    /// only (owner reversed the v1 Slack-only scoping).
    func testDigestsBadgeCountIncludesStreamAndDecisionUnread() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try await manager.dbPool.write { db in
            // A workspace user (account #1) so fetch() runs its full path,
            // where unreadDigestCount is computed (the no-uid path leaves it 0).
            _ = try TestDatabase.insertSlackAccount(db, currentUserID: "U042")
            // 2 unread Slack digests (insertDigest leaves read_at NULL);
            // distinct channels to clear the (channel,type,period) UNIQUE key.
            try TestDatabase.insertDigest(db, channelID: "C001")
            try TestDatabase.insertDigest(db, channelID: "C002")
            // Stream digests: 1 unread, 1 read.
            _ = try TestDatabase.insertStreamDigest(db, readAt: nil)
            _ = try TestDatabase.insertStreamDigest(db, readAt: "2026-06-20T00:00:00Z")
            // Decisions: 1 never-seen (unread), 1 seen (read),
            // 1 seen-but-re-flagged (unread).
            _ = try TestDatabase.insertIdea(db, kind: "decision", seenAt: nil)
            _ = try TestDatabase.insertIdea(db, kind: "decision", seenAt: "2026-06-20T00:00:00Z")
            _ = try TestDatabase.insertIdea(
                db, kind: "decision", needsReview: true, seenAt: "2026-06-20T00:00:00Z"
            )
            // A non-decision idea must NOT contribute to the decision unread.
            _ = try TestDatabase.insertIdea(db, kind: "idea", status: "proposed")
        }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.unreadDigestCount, 2)
        XCTAssertEqual(vm.unreadStreamCount, 1)
        XCTAssertEqual(vm.unreadDecisionCount, 2)
        XCTAssertEqual(vm.digestsBadgeCount, 2 + 1 + 2)
        XCTAssertEqual(
            vm.digestsBadgeCount,
            vm.unreadDigestCount + vm.unreadStreamCount + vm.unreadDecisionCount
        )
    }

    func testDigestsBadgeCountIsZeroOnEmptyDB() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.digestsBadgeCount, 0)
    }
}

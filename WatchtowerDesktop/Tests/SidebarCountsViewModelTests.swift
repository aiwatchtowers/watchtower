import XCTest
import GRDB
@testable import WatchtowerDesktop

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
}

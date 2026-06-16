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
}

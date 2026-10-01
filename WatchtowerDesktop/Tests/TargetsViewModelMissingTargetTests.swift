import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// A target deleted in another process after the screen loaded it: the edit
/// must fail visibly and the vanished row must leave the list, not linger to
/// fail again on every retry.
@MainActor
final class TargetsViewModelMissingTargetTests: XCTestCase {

    func testEditOfATargetDeletedElsewhere_ReportsIt_AndDropsTheRow() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let id = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: "gone soon", periodStart: "2026-09-01", periodEnd: "2026-09-30")
        }
        let vm = TargetsViewModel(dbManager: manager)
        vm.load()
        let stale = try XCTUnwrap((vm.todayTargets + vm.allTargets).first { $0.id == id })

        // No `load()` after this delete: the VM's observation never sees
        // another process's write, which is exactly the case under test.
        try manager.dbPool.write { db in try db.execute(sql: "DELETE FROM targets WHERE id = ?", arguments: [id]) }

        vm.updatePriority(stale, to: "high")

        XCTAssertEqual(
            vm.errorMessage,
            "Failed to update priority: \(TargetNotFoundError(id: id).localizedDescription)"
        )
        XCTAssertFalse((vm.todayTargets + vm.allTargets).contains { $0.id == id })
    }
}

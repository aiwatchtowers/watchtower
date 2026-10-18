import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Statistics screens load from the observation's first value (#591), so
/// a write made right after a (re)start is never lost between a load and the
/// observation's registration — no retry needed.
@MainActor
final class UserStatsViewModelObservationTests: XCTestCase {

    func testAWriteRightAfterARestart_IsSeen() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let vm = UserStatsViewModel(dbManager: manager)
        vm.startObserving()
        vm.stopObserving()
        XCTAssertNil(vm.observationTask)

        vm.startObserving()
        defer { vm.stopObserving() }
        XCTAssertTrue(vm.isLoading, "the screen shows loading until the first value")
        try await manager.dbPool.write { db in try TestDatabase.insertUser(db, id: "U001") }

        let deadline = ContinuousClock.now + .seconds(3)
        while vm.stats.count != 1 || vm.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(vm.stats.map(\.id), ["U001"])
        XCTAssertFalse(vm.isLoading)
    }
}

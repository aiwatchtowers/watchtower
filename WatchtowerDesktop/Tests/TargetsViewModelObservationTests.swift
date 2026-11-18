import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Targets screen's observation lives only while the screen is shown
/// (#591): a stopped VM's observation task is cancelled and ends, a released
/// VM's task ends at the next change, and a restart follows writes again.
@MainActor
final class TargetsViewModelObservationTests: XCTestCase {

    private var bump = 0

    func testStopObserving_EndsTheTask_AndAStartFollowsWritesAgain() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let vm = TargetsViewModel(dbManager: manager)

        vm.startObserving()
        await untilObserved { vm.observationLive }
        try insertTarget(manager, text: "seen while observing")
        await untilObserved { self.targetCount(vm) == 1 }
        XCTAssertEqual(targetCount(vm), 1, "a write refreshes the observing VM")

        let task = try XCTUnwrap(vm.observationTask)
        vm.stopObserving()
        XCTAssertNil(vm.observationTask, "stop clears the task")
        XCTAssertTrue(task.isCancelled, "stop cancels the task")
        await task.value // the cancelled observation loop ends (else a hang)
        XCTAssertFalse(vm.observationLive)

        try insertTarget(manager, text: "written off screen")
        vm.startObserving()
        defer { vm.stopObserving() }
        XCTAssertEqual(targetCount(vm), 2, "a restart reloads at once")
        await untilObserved { vm.observationLive }
        try insertTarget(manager, text: "seen after the restart")
        await untilObserved { self.targetCount(vm) == 3 }
        XCTAssertEqual(targetCount(vm), 3, "the restarted observation follows writes again")
    }

    func testAReleasedObservingVM_EndsItsObservationAtTheNextChange() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try insertTarget(manager, text: "bumped below")
        weak var released: TargetsViewModel?
        let task: Task<Void, Never>
        do {
            let vm = TargetsViewModel(dbManager: manager)
            vm.startObserving()
            task = try XCTUnwrap(vm.observationTask)
            // The baseline is in, so the next write is a change the loop sees.
            await untilObserved { [weak vm] in vm?.observationLive == true }
            released = vm
        }
        XCTAssertNil(released, "nothing else holds the VM")
        XCTAssertFalse(task.isCancelled, "no view stopped it")
        try bumpTargets(manager)
        // The loop ends at that change instead of living on (else a hang).
        await task.value
    }

    // MARK: - Helpers

    private func insertTarget(_ manager: DatabaseManager, text: String) throws {
        _ = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: text, periodStart: "2026-09-01", periodEnd: "2026-09-30")
        }
    }

    /// A change the observation sees (it tracks the latest `updated_at`).
    private func bumpTargets(_ manager: DatabaseManager) throws {
        bump += 1
        let stamp = String(format: "9999-01-01T00:00:00.%08d", bump)
        try manager.dbPool.write { db in
            try db.execute(sql: "UPDATE targets SET updated_at = ?", arguments: [stamp])
        }
    }

    private func targetCount(_ vm: TargetsViewModel) -> Int {
        Set((vm.todayTargets + vm.allTargets).map(\.id)).count
    }
}

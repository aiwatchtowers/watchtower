import XCTest
import GRDB
import os
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
        try insertTarget(manager, text: "seen while observing")
        try await waitUntil(manager) { self.targetCount(vm) == 1 }
        XCTAssertEqual(targetCount(vm), 1, "a write refreshes the observing VM")

        let task = try XCTUnwrap(vm.observationTask)
        vm.stopObserving()
        XCTAssertNil(vm.observationTask, "stop clears the task")
        XCTAssertTrue(task.isCancelled, "stop cancels the task")
        let ended = await hasEnded(task, manager: manager, bumping: false)
        XCTAssertTrue(ended, "the cancelled observation loop ends")

        try insertTarget(manager, text: "written off screen")
        vm.startObserving()
        defer { vm.stopObserving() }
        XCTAssertEqual(targetCount(vm), 2, "a restart reloads at once")
        try insertTarget(manager, text: "seen after the restart")
        try await waitUntil(manager) { self.targetCount(vm) == 3 }
        XCTAssertEqual(targetCount(vm), 3, "the restarted observation follows writes again")
    }

    func testAReleasedObservingVM_EndsItsObservationAtTheNextChange() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try insertTarget(manager, text: "bumped below")
        var vm: TargetsViewModel? = TargetsViewModel(dbManager: manager)
        vm?.startObserving()
        let task = try XCTUnwrap(vm?.observationTask)
        weak var released = vm

        vm = nil
        XCTAssertNil(released, "nothing else holds the VM")
        XCTAssertFalse(task.isCancelled, "no view stopped it")
        let ended = await hasEnded(task, manager: manager, bumping: true)
        XCTAssertTrue(ended, "the released VM's observation ends instead of living on")
    }

    // MARK: - Helpers

    private func insertTarget(_ manager: DatabaseManager, text: String) throws {
        _ = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: text, periodStart: "2026-09-01", periodEnd: "2026-09-30")
        }
    }

    /// A change the observation sees (it tracks the latest `updated_at`):
    /// retried until the VM reflects it, so a write that landed before the
    /// observation registered is never the only one.
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

    private func waitUntil(_ manager: DatabaseManager, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try bumpTargets(manager)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Whether `task` finishes within 3 s, bumping `targets` meanwhile when
    /// the loop only notices the end on its next value.
    private func hasEnded(_ task: Task<Void, Never>, manager: DatabaseManager, bumping: Bool) async -> Bool {
        let done = OSAllocatedUnfairLock(initialState: false)
        let waiter = Task {
            await task.value
            done.withLock { $0 = true }
        }
        defer { waiter.cancel() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !done.withLock({ $0 }), ContinuousClock.now < deadline {
            if bumping { try? bumpTargets(manager) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return done.withLock { $0 }
    }
}

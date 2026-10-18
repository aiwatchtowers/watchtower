import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Targets screen's observation lives only while the screen is shown
/// (#591): a stopped VM no longer re-reads on every `targets` write, and
/// coming back to the screen starts it again.
@MainActor
final class TargetsViewModelObservationTests: XCTestCase {

    func testStopObserving_StopsRefreshing_AndAStartResumesIt() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let vm = TargetsViewModel(dbManager: manager)

        vm.startObserving()
        try await letTheObservationStart()
        try insertTarget(manager, text: "seen while observing")
        try await waitForTargetCount(vm, 1)
        XCTAssertEqual(targetCount(vm), 1, "a write refreshes the observing VM")

        vm.stopObserving()
        try insertTarget(manager, text: "written off screen")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(targetCount(vm), 1, "a stopped VM no longer reads on writes")

        vm.startObserving()
        defer { vm.stopObserving() }
        XCTAssertEqual(targetCount(vm), 2, "a restart reloads at once")
        try await letTheObservationStart()
        try insertTarget(manager, text: "seen after the restart")
        try await waitForTargetCount(vm, 3)
        XCTAssertEqual(targetCount(vm), 3, "the restarted observation follows writes again")
    }

    /// The observation drops its first value, so a write landing before it
    /// registers would be folded into that dropped value.
    private func letTheObservationStart() async throws {
        try await Task.sleep(for: .milliseconds(200))
    }

    private func insertTarget(_ manager: DatabaseManager, text: String) throws {
        _ = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: text, periodStart: "2026-09-01", periodEnd: "2026-09-30")
        }
    }

    private func targetCount(_ vm: TargetsViewModel) -> Int {
        Set((vm.todayTargets + vm.allTargets).map(\.id)).count
    }

    private func waitForTargetCount(_ vm: TargetsViewModel, _ expected: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while targetCount(vm) != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

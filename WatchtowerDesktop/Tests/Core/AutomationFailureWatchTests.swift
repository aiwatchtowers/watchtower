import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

@MainActor
private final class FailureNotifier: AutomationRunNotifying {
    private(set) var failedRunIDs: [Int64] = []
    private(set) var disabled: [(runID: Int64, reason: String)] = []

    func runFinished(
        name: String,
        status: AutomationRunStatus,
        summary: String,
        error: String,
        automationID: Int64,
        runID: Int64
    ) {
        failedRunIDs.append(runID)
    }

    func automationDisabled(name: String, reason: String, automationID: Int64, runID: Int64) {
        disabled.append((runID, reason))
    }
}

/// #584: background failures and auto-disable are no longer silent.
@MainActor
final class AutomationFailureWatchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_152_000) // 2026-10-16T12:00:00Z
    private var defaults: UserDefaults!
    private var suite = ""
    private var notifier: FailureNotifier!

    override func setUp() async throws {
        try await super.setUp()
        suite = "AutomationFailureWatchTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        notifier = FailureNotifier()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func item(_ id: Int64, _ run: AutomationRun?) -> AutomationListItem {
        let automation = Automation(
            id: id, slug: "a\(id)", scope: .personal, projectID: nil, path: "/tmp/a\(id).md", name: "A\(id)",
            triggerKind: "schedule", triggerSpecJSON: "{}", missedPolicy: "run_once", concurrency: 1,
            budgetTokens: 50000, budgetMinutes: 5, pauseTimeoutHours: 72, permissions: [], outputs: [],
            recipeText: "", contentHash: "", approvalHash: "h", confirmedHash: "h", parseError: "", enabled: true,
            lastScheduledFor: nil, nextRunAt: nil, removedAt: nil
        )
        return AutomationListItem(automation: automation, lastRun: run, activeRun: nil, tokens7d: 0, badges: [],
                                  triggerText: "")
    }

    private func run(
        _ id: Int64,
        automation: Int64,
        trigger: String = "schedule",
        status: AutomationRunStatus = .failed,
        error: String = "boom",
        finishedAgo: TimeInterval = 60
    ) -> AutomationRun {
        AutomationRun(id: id, automationID: automation, trigger: trigger, status: status, error: error,
                      finishedAt: now.addingTimeInterval(-finishedAgo))
    }

    private func watch() -> AutomationFailureWatch {
        AutomationFailureWatch(defaults: defaults, notifier: notifier)
    }

    func testBadgeCountsUnseenFailuresUntilTheCardIsOpened() {
        let w = watch()
        let failed = item(1, run(10, automation: 1))
        let cancelled = item(2, run(11, automation: 2, status: .cancelled))
        let dryRun = item(3, run(12, automation: 3, trigger: "dry_run"))
        let ok = item(4, run(13, automation: 4, status: .succeeded))
        let timedOut = item(5, run(14, automation: 5, trigger: "manual", status: .timedOut))
        let items = [failed, cancelled, dryRun, ok, timedOut, item(6, nil)]
        XCTAssertEqual(w.unseenCount(items), 2)

        w.markSeen(failed)
        XCTAssertEqual(w.unseenCount(items), 1)
        // A newer failure of the same automation counts again.
        XCTAssertEqual(w.unseenCount([item(1, run(20, automation: 1))]), 1)
        // A newer run that did not fail clears it without opening the card.
        XCTAssertEqual(w.unseenCount([item(5, run(21, automation: 5, status: .succeeded))]), 0)
        // Seen state survives a new watch (an app restart).
        XCTAssertEqual(watch().unseenCount(items), 1)
    }

    func testBackgroundFailureNotifiesOncePerAutomationPerDay() {
        let w = watch()
        w.notifyNewFailures([item(1, run(10, automation: 1)), item(2, run(11, automation: 2, trigger: "event"))],
                            now: now)
        XCTAssertEqual(notifier.failedRunIDs, [10, 11])

        // The same run polled again, and a second failure within the day: no notice.
        w.notifyNewFailures([item(1, run(10, automation: 1))], now: now)
        w.notifyNewFailures([item(1, run(12, automation: 1, trigger: "catch_up"))], now: now.addingTimeInterval(3600))
        XCTAssertEqual(notifier.failedRunIDs, [10, 11])
        // The suppressed run never notifies late.
        w.notifyNewFailures([item(1, run(12, automation: 1, trigger: "catch_up", finishedAgo: -3600))],
                            now: now.addingTimeInterval(AutomationFailureWatch.noticeInterval + 1))
        XCTAssertEqual(notifier.failedRunIDs, [10, 11])

        // A day later a new failure notifies again.
        let later = now.addingTimeInterval(AutomationFailureWatch.noticeInterval + 60)
        w.notifyNewFailures([item(1, AutomationRun(id: 13, automationID: 1, trigger: "schedule", status: .expired,
                                                   finishedAt: later))], now: later)
        XCTAssertEqual(notifier.failedRunIDs, [10, 11, 13])
    }

    func testManualButtonAndOldFailuresDoNotNotify() {
        let w = watch()
        w.notifyNewFailures([
            item(1, run(10, automation: 1, trigger: "manual")),
            item(2, run(11, automation: 2, trigger: "button")),
            item(3, run(12, automation: 3, trigger: "dry_run")),
            item(4, run(13, automation: 4, status: .cancelled)),
            item(5, run(14, automation: 5, finishedAgo: AutomationFailureWatch.noticeInterval + 1))
        ], now: now)
        XCTAssertEqual(notifier.failedRunIDs, [])
        XCTAssertTrue(notifier.disabled.isEmpty)
    }

    func testAutoDisableAlwaysNotifiesWhateverStartedIt() {
        let w = watch()
        let error = "timed out" + AutomationFailureWatch.disabledMarker + "runaway script — check and re-enable"
        // A background failure inside the day's window first, so the cap is spent.
        w.notifyNewFailures([item(1, run(10, automation: 1))], now: now)
        w.notifyNewFailures([
            item(1, run(11, automation: 1, status: .timedOut, error: error)),
            item(2, run(12, automation: 2, trigger: "manual", status: .timedOut, error: error))
        ], now: now)
        XCTAssertEqual(notifier.failedRunIDs, [10])
        XCTAssertEqual(notifier.disabled.map(\.runID), [11, 12])
        XCTAssertEqual(notifier.disabled.first?.reason, "runaway script — check and re-enable")
    }

    /// The view model: a failure feeds the sidebar badge until the owner
    /// opens the card on the visible tab.
    func testViewModelBadgeClearsWhenTheCardIsOpened() throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let id = try pool.write { db -> Int64 in
            let id = try TestDatabase.insertAutomation(db, slug: "nightly")
            try TestDatabase.insertAutomationRun(db, automationID: id, trigger: "schedule", status: "failed",
                                                 error: "boom", finishedAt: "2026-10-16T11:59:00Z")
            return id
        }
        let fixed = now
        let vm = AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: NoopRunner()),
                                      failureWatch: watch(), now: { fixed }, sleep: { _ in })
        vm.refresh()
        XCTAssertEqual(vm.unseenFailureCount, 1)
        XCTAssertEqual(vm.badgeCount, vm.attentionCount + 1)
        XCTAssertEqual(notifier.failedRunIDs.count, 1)

        vm.select(id) // tab not visible yet: not seen
        XCTAssertEqual(vm.unseenFailureCount, 1)
        vm.setTabVisible(true)
        XCTAssertEqual(vm.unseenFailureCount, 0)
        XCTAssertEqual(notifier.failedRunIDs.count, 1)
    }
}

private struct NoopRunner: CLIRunnerProtocol {
    func run(args: [String]) async throws -> Data { Data() }
}

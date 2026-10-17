import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

@MainActor
private final class FailureNotifier: AutomationRunNotifying {
    private(set) var failedRunIDs: [Int64] = []
    private(set) var disabled: [(runID: Int64?, reason: String)] = []
    private(set) var summaries: [Int] = []

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

    func automationDisabled(name: String, reason: String, automationID: Int64, runID: Int64?) {
        disabled.append((runID, reason))
    }

    func automationsFailed(count: Int) {
        summaries.append(count)
    }

    private(set) var disabledSummaries: [Int] = []

    func automationsDisabled(count: Int) {
        disabledSummaries.append(count)
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

    private func item(_ id: Int64, disabledAt: Date? = nil) -> AutomationListItem {
        let automation = Automation(
            id: id, slug: "a\(id)", name: "A\(id)", triggerKind: "schedule", enabled: disabledAt == nil,
            disabledReason: disabledAt == nil ? "" : "runaway script", disabledAt: disabledAt
        )
        return AutomationListItem(automation: automation, lastRun: nil, activeRun: nil, tokens7d: 0, badges: [],
                                  triggerText: "")
    }

    private func run(
        _ id: Int64,
        automation: Int64,
        trigger: String = "schedule",
        status: AutomationRunStatus = .failed,
        errorKind: String = "script",
        finishedAgo: TimeInterval = 60
    ) -> AutomationRun {
        AutomationRun(id: id, automationID: automation, trigger: trigger, status: status, error: "boom",
                      errorKind: errorKind, finishedAt: now.addingTimeInterval(-finishedAgo))
    }

    private func watch(workspace: String = "/ws/a.db") -> AutomationFailureWatch {
        AutomationFailureWatch(defaults: defaults, workspace: workspace, notifier: notifier)
    }

    /// `existing` defaults to the listed ids.
    private func notify(
        _ w: AutomationFailureWatch,
        _ items: [AutomationListItem],
        runs: [Int64: AutomationRun],
        existing: Set<Int64>? = nil,
        now: Date
    ) {
        w.notify(items, runs: runs, existing: existing ?? Set(items.map(\.id)), now: now)
    }

    private func runs(_ list: AutomationRun...) -> [Int64: AutomationRun] {
        Dictionary(uniqueKeysWithValues: list.map { ($0.automationID, $0) })
    }

    func testBadgeCountsUnseenFailuresUntilTheCardIsOpened() {
        let w = watch()
        let items = (1...6).map { item(Int64($0)) }
        let ended = runs(
            run(10, automation: 1),
            run(11, automation: 2, status: .cancelled),
            run(13, automation: 4, status: .succeeded),
            run(14, automation: 5, trigger: "manual", status: .timedOut)
        )
        XCTAssertEqual(w.unseenCount(items, runs: ended), 2)

        w.markSeen(1, runs: ended)
        XCTAssertEqual(w.unseenCount(items, runs: ended), 1)
        // A newer failure of the same automation counts again.
        XCTAssertEqual(w.unseenCount([item(1)], runs: runs(run(20, automation: 1))), 1)
        // A newer run that did not fail clears it without opening the card.
        XCTAssertEqual(w.unseenCount([item(5)], runs: runs(run(21, automation: 5, status: .succeeded))), 0)
        // Seen state survives a new watch (an app restart) but is per workspace.
        XCTAssertEqual(watch().unseenCount(items, runs: ended), 1)
        XCTAssertEqual(watch(workspace: "/ws/b.db").unseenCount(items, runs: ended), 2)
    }

    func testBackgroundFailureNotifiesOncePerAutomationPerDay() {
        let w = watch()
        notify(w, [item(1), item(2)], runs: runs(run(10, automation: 1), run(11, automation: 2, trigger: "event")),
               now: now)
        XCTAssertEqual(notifier.failedRunIDs, [10, 11])

        // The same run polled again, and a second failure within the day: no notice.
        notify(w, [item(1)], runs: runs(run(10, automation: 1)), now: now)
        notify(w, [item(1)], runs: runs(run(12, automation: 1, trigger: "catch_up")), now: now.addingTimeInterval(3600))
        XCTAssertEqual(notifier.failedRunIDs, [10, 11])
        // The suppressed run never notifies late.
        notify(w, [item(1)], runs: runs(run(12, automation: 1, trigger: "catch_up", finishedAgo: -3600)),
               now: now.addingTimeInterval(AutomationFailureWatch.noticeInterval + 1))
        XCTAssertEqual(notifier.failedRunIDs, [10, 11])

        // A day later a new failure notifies again.
        let later = now.addingTimeInterval(AutomationFailureWatch.noticeInterval + 60)
        notify(w, [item(1)], runs: runs(AutomationRun(id: 13, automationID: 1, trigger: "schedule", status: .expired,
                                                      finishedAt: later)), now: later)
        XCTAssertEqual(notifier.failedRunIDs, [10, 11, 13])
    }

    func testManualButtonRestartAndOldFailuresDoNotNotify() {
        let w = watch()
        let items = (1...5).map { item(Int64($0)) }
        notify(w, items, runs: runs(
            run(10, automation: 1, trigger: "manual"),
            run(11, automation: 2, trigger: "button"),
            run(12, automation: 3, errorKind: "interrupted"),
            run(13, automation: 4, status: .cancelled),
            run(14, automation: 5, finishedAgo: AutomationFailureWatch.noticeInterval + 1)
        ), now: now)
        XCTAssertEqual(notifier.failedRunIDs, [])
        XCTAssertTrue(notifier.disabled.isEmpty)
        // The restart still counts on the badge.
        XCTAssertEqual(w.unseenCount([item(3)], runs: runs(run(12, automation: 3, errorKind: "interrupted"))), 1)
    }

    func testMoreThanTwoFailuresInOnePollPostOneSummary() {
        let w = watch()
        notify(w, (1...3).map { item(Int64($0)) },
               runs: runs(run(10, automation: 1), run(11, automation: 2), run(12, automation: 3)), now: now)
        XCTAssertEqual(notifier.failedRunIDs, [])
        XCTAssertEqual(notifier.summaries, [3])
        // Each counted toward its automation's daily window.
        notify(w, [item(1)], runs: runs(run(20, automation: 1)), now: now.addingTimeInterval(60))
        XCTAssertEqual(notifier.failedRunIDs, [])
    }

    func testAutoDisableNotifiesOncePerDisableWhateverStartedIt() {
        let w = watch()
        // The day's failure window is spent and the disable is old: it still posts.
        notify(w, [item(1)], runs: runs(run(10, automation: 1)), now: now)
        let old = now.addingTimeInterval(-3 * AutomationFailureWatch.noticeInterval)
        let manual = run(12, automation: 2, trigger: "manual", status: .cancelled)
        notify(w, [item(1, disabledAt: now), item(2, disabledAt: old)],
               runs: runs(run(11, automation: 1, status: .timedOut), manual), now: now)
        XCTAssertEqual(notifier.failedRunIDs, [10])
        XCTAssertEqual(notifier.disabled.map(\.runID), [11, 12])
        XCTAssertEqual(notifier.disabled.first?.reason, "runaway script")

        // Polled again: nothing new; a later disable (after a re-enable) posts again.
        notify(w, [item(1, disabledAt: now)], runs: [:], now: now)
        notify(w, [item(1, disabledAt: now.addingTimeInterval(60))], runs: [:], now: now)
        XCTAssertEqual(notifier.disabled.map(\.runID), [11, 12, nil])
    }

    /// Verify F1: with the day's window unspent, a background run that
    /// disabled its automation posts only the disabled notice.
    func testRunawayBackgroundRunPostsOnlyTheDisabledNotice() {
        let w = watch()
        notify(w, [item(1, disabledAt: now)], runs: runs(run(10, automation: 1, status: .timedOut)), now: now)
        XCTAssertEqual(notifier.failedRunIDs, [])
        XCTAssertEqual(notifier.disabled.map(\.runID), [10])
        // It still counts on the badge.
        XCTAssertEqual(w.unseenCount([item(1, disabledAt: now)], runs: runs(run(10, automation: 1, status: .timedOut))), 1)
    }

    /// Verify F3: more than two disables in one pass post one summary.
    func testMoreThanTwoDisablesInOnePollPostOneSummary() {
        let w = watch()
        notify(w, (1...3).map { item(Int64($0), disabledAt: now) }, runs: [:], now: now)
        XCTAssertTrue(notifier.disabled.isEmpty)
        XCTAssertEqual(notifier.disabledSummaries, [3])
        notify(w, (1...3).map { item(Int64($0), disabledAt: now) }, runs: [:], now: now)
        XCTAssertEqual(notifier.disabledSummaries, [3], "each disable posts once")
    }

    /// Verify F2: a recipe whose file is briefly gone leaves the list but
    /// keeps its row; its state stays, so nothing posts twice.
    func testStateOfARemovedRecipeIsKept() {
        let w = watch()
        notify(w, [item(1, disabledAt: now)], runs: runs(run(10, automation: 1)), now: now)
        notify(w, [], runs: [:], existing: [1], now: now)
        notify(w, [item(1, disabledAt: now)], runs: runs(run(10, automation: 1)), now: now)
        XCTAssertEqual(notifier.disabled.count, 1)
    }

    func testStateOfGoneAutomationsIsPruned() {
        let w = watch()
        notify(w, [item(1)], runs: runs(run(10, automation: 1)), now: now)
        w.markSeen(1, runs: runs(run(10, automation: 1)))
        let other = watch(workspace: "/ws/b.db")
        notify(other, [item(1)], runs: runs(run(10, automation: 1)), now: now)

        notify(w, [], runs: [:], now: now)
        for key in [AutomationFailureWatch.handledKey, AutomationFailureWatch.noticeKey, AutomationFailureWatch.seenKey,
                    AutomationFailureWatch.disabledKey] {
            let stored = defaults.dictionary(forKey: key) ?? [:]
            XCTAssertFalse(stored.keys.contains("/ws/a.db|1"), key)
        }
        XCTAssertNotNil((defaults.dictionary(forKey: AutomationFailureWatch.handledKey) ?? [:])["/ws/b.db|1"],
                        "another workspace keeps its state")
    }

    // MARK: - View model

    private func makeViewModel(looking: Bool = true) throws -> (AutomationsViewModel, Int64, () -> Void) {
        let (pool, path) = try TestDatabase.createPool()
        let id = try pool.write { db -> Int64 in
            let id = try TestDatabase.insertAutomation(db, slug: "nightly")
            try TestDatabase.insertAutomationRun(db, automationID: id, trigger: "schedule", status: "failed",
                                                 error: "boom", finishedAt: "2026-10-16T11:59:00Z")
            // A later dry run never hides the failure.
            try TestDatabase.insertAutomationRun(db, automationID: id, trigger: "dry_run", status: "succeeded",
                                                 finishedAt: "2026-10-16T11:59:30Z")
            return id
        }
        let fixed = now
        let vm = AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: NoopRunner()),
                                      failureWatch: watch(workspace: path), isOwnerLooking: { looking },
                                      now: { fixed }, sleep: { _ in })
        return (vm, id, { TestDatabase.cleanup(path: path) })
    }

    /// A failure feeds the sidebar badge until the owner opens the card on
    /// the visible tab of an active app.
    func testViewModelBadgeClearsWhenTheCardIsOpened() throws {
        let (vm, id, cleanup) = try makeViewModel()
        defer { cleanup() }
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

    func testViewModelNotSeenWhileTheAppIsInactive() throws {
        let (vm, id, cleanup) = try makeViewModel(looking: false)
        defer { cleanup() }
        vm.select(id)
        vm.setTabVisible(true)
        XCTAssertEqual(vm.unseenFailureCount, 1)
    }
}

private struct NoopRunner: CLIRunnerProtocol {
    func run(args: [String]) async throws -> Data { Data() }
}

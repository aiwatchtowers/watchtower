import Foundation
import os
import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// Board #842 (owner decision ask #337): the hub's CLI runners wake on a
/// session state change (or a phone request) at once — no sooner than 5 s
/// after their last pass, the old poll — and otherwise at most once per idle
/// interval; the asks fast lane keeps its cadence.
final class HubRunnerWakeTests: XCTestCase {
    // MARK: - The wait

    func testASignalEndsAWaitInProgressAtOnceOnceTheGapIsOver() async {
        let sleeper = ManualSleeper()
        let clock = TestInstant()
        let wake = sleeper.wake(clock)
        let ended = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            await wake.wait(upTo: .seconds(15))
            ended.withLock { $0 = true }
        }
        await awaitHubCondition("the wait parked its timer") { sleeper.parkedCount == 1 }
        XCTAssertFalse(ended.withLock { $0 })

        clock.advance(by: .seconds(6))
        wake.signal()
        await awaitHubCondition("the signal ended the wait") { ended.withLock { $0 } }
        XCTAssertEqual(sleeper.requested, [.seconds(15)], "no gap left to wait")
        XCTAssertEqual(sleeper.fired, 0, "the timer never ran out")
        await task.value
    }

    func testASignalInsideTheGapWaitsOnlyTheRestOfIt() async {
        let sleeper = ManualSleeper()
        let clock = TestInstant()
        let wake = sleeper.wake(clock)
        let ended = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            await wake.wait(upTo: .seconds(15))
            ended.withLock { $0 = true }
        }
        await awaitHubCondition("the wait parked its timer") { sleeper.parkedCount == 1 }

        clock.advance(by: .seconds(2))
        wake.signal()
        wake.signal()
        await awaitHubCondition("the rest of the gap is parked") { sleeper.requested == [.seconds(15), .seconds(3)] }
        XCTAssertEqual(sleeper.parkedCount, 1, "the 15 s timer was dropped")
        XCTAssertFalse(ended.withLock { $0 })

        sleeper.fireAll()
        await awaitHubCondition("the gap ended the wait") { ended.withLock { $0 } }
        await task.value
    }

    func testASignalSentBetweenWaitsEndsTheNextWaitAfterTheGap() async {
        let sleeper = ManualSleeper()
        let clock = TestInstant()
        let wake = sleeper.wake(clock)
        wake.signal()
        let first = Task { await wake.wait(upTo: .seconds(15)) }
        await awaitHubCondition("only the gap is parked") { sleeper.parkedCount == 1 }
        XCTAssertEqual(sleeper.requested, [.seconds(5)], "a pending signal takes no timer")
        sleeper.fireAll()
        await first.value

        // Taken once: the wait after it runs its timer.
        let second = Task { await wake.wait(upTo: .seconds(15)) }
        await awaitHubCondition("the next wait parked its timer") { sleeper.parkedCount == 1 }
        XCTAssertEqual(sleeper.requested.last, .seconds(15))
        sleeper.fireAll()
        await second.value
    }

    func testWithoutASignalTheWaitEndsWhenItsTimerDoes() async {
        let sleeper = ManualSleeper()
        let wake = HubRunnerWake(sleep: sleeper.sleep)
        let ended = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            await wake.wait(upTo: .seconds(15))
            ended.withLock { $0 = true }
        }
        await awaitHubCondition("the wait parked its timer") { sleeper.parkedCount == 1 }
        await Task.yield()
        XCTAssertFalse(ended.withLock { $0 })

        sleeper.fireAll()
        await awaitHubCondition("the timer ended the wait") { ended.withLock { $0 } }
        XCTAssertEqual(sleeper.requested, [.seconds(15)], "a timed-out wait adds no gap")
        await task.value
    }

    func testCancellingTheTaskEndsTheWait() async {
        let sleeper = ManualSleeper()
        let wake = HubRunnerWake(sleep: sleeper.sleep)
        let task = Task { await wake.wait(upTo: .seconds(15)) }
        await awaitHubCondition("the wait parked its timer") { sleeper.parkedCount == 1 }
        task.cancel()
        await task.value
        XCTAssertEqual(sleeper.fired, 0)
    }

    func testAZeroWaitReturnsAtOnce() async {
        let sleeper = ManualSleeper()
        let wake = HubRunnerWake(sleep: sleeper.sleep)
        await wake.wait(upTo: .zero)
        XCTAssertEqual(sleeper.requested, [])
    }

    /// A loop left over from a restart that waits beside the new one ends
    /// the parked one instead of losing it.
    func testASecondWaiterEndsTheParkedOne() async {
        let sleeper = ManualSleeper()
        let wake = HubRunnerWake(sleep: sleeper.sleep)
        let firstEnded = OSAllocatedUnfairLock(initialState: false)
        let first = Task {
            await wake.wait(upTo: .seconds(15))
            firstEnded.withLock { $0 = true }
        }
        await awaitHubCondition("the first wait parked") { sleeper.parkedCount == 1 }
        let second = Task { await wake.wait(upTo: .seconds(15)) }
        await awaitHubCondition("the first wait ended") { firstEnded.withLock { $0 } }
        await first.value
        await awaitHubCondition("the second wait parked") { sleeper.parkedCount == 1 }
        sleeper.fireAll()
        await second.value
    }

    func testTheWaitRunsUntilTheDeferredRequestCappedAtIdle() {
        let now = ContinuousClock.now
        let idle = Duration.seconds(15)
        XCTAssertEqual(HubRunnerWake.duration(until: nil, now: now, idle: idle), idle)
        XCTAssertEqual(HubRunnerWake.duration(until: now + .seconds(3), now: now, idle: idle), .seconds(3))
        XCTAssertEqual(HubRunnerWake.duration(until: now + .seconds(40), now: now, idle: idle), idle)
        XCTAssertEqual(HubRunnerWake.duration(until: now - .seconds(1), now: now, idle: idle), .zero)
    }

    // MARK: - Cadences

    func testTheRunnersIdleAt15SecondsAndTheFastLaneKeepsItsCadence() {
        XCTAssertEqual(WorkbenchGitRefresher.Timing.standard.idle, .seconds(15))
        XCTAssertEqual(SessionReportSummaryRunner.Timing.standard.idle, .seconds(15))
        XCTAssertEqual(SessionReportRunner.Timing.standard.idle, .seconds(15))
        // Events cost no more passes than the old 5 s poll.
        XCTAssertEqual(HubRunnerWake.standardMinimumGap, .seconds(5))
        // The coalescing spacings are what they were: an event is as fresh as before.
        XCTAssertEqual(WorkbenchGitRefresher.Timing.standard.minSpacing, .seconds(30))
        XCTAssertEqual(SessionReportSummaryRunner.Timing.standard.minSpacing, .seconds(5))
        XCTAssertEqual(SessionReportRunner.Timing.standard.stateSpacing, .seconds(5))
        // The asks fast lane and the urgent tick are untouched.
        XCTAssertEqual(SlicePublisher.Timing.standard.fastWindow, .seconds(1))
        XCTAssertEqual(SlicePublisher.Timing.standard.fastSpacing, .seconds(2))
        XCTAssertEqual(SlicePublisher.Timing.standard.urgentTick, .seconds(10))
        XCTAssertEqual(SlicePublisher.Timing.standard.tick, .seconds(30))
    }

    // MARK: - Git refresher

    func testGitRefresherWakesOnASessionChangeAtOnceAndOtherwiseOncePerIdle() async {
        let sleeper = ManualSleeper()
        let clock = TestInstant()
        let listings = OSAllocatedUnfairLock(initialState: 0)
        let runs = OSAllocatedUnfairLock(initialState: 0)
        let refresher = gitRefresher(sleeper: sleeper, clock: clock, fetch: { id in
            runs.withLock { $0 += 1 }
            return WorkbenchGitStatus(workbenchID: id, branch: "main", detached: false, changes: 0)
        }, workbenchIDs: {
            listings.withLock { $0 += 1 }
            return [7]
        })
        refresher.start()
        defer { refresher.stop() }
        await awaitHubCondition("the first pass ran and the loop waits idle") { sleeper.requested == [.seconds(15)] }
        XCTAssertEqual(listings.withLock { $0 }, 1)
        XCTAssertEqual(runs.withLock { $0 }, 1)

        // No event: one pass per idle wait, never more.
        clock.advance(by: .seconds(20))
        sleeper.fireAll()
        await awaitHubCondition("the idle wake ran one pass") { sleeper.requested.count == 2 }
        XCTAssertEqual(listings.withLock { $0 }, 2)
        XCTAssertEqual(sleeper.requested, [.seconds(15), .seconds(15)])

        // A change past the 5 s gap but inside the 30 s spacing wakes the
        // loop at once; the pass defers the run and the loop waits only
        // until it is due.
        clock.advance(by: .seconds(5))
        refresher.sessionStateChanged(workbenchID: 7)
        await awaitHubCondition("the change woke the loop") { listings.withLock { $0 } == 3 }
        await awaitHubCondition("the loop waits for the deferred run") { sleeper.requested.count == 3 }
        XCTAssertEqual(sleeper.requested.last, .seconds(5), "5 s of the 30 s spacing left")
        XCTAssertEqual(runs.withLock { $0 }, 1)
        XCTAssertEqual(sleeper.fired, 1, "only the first idle wait ran out")

        clock.advance(by: .seconds(5))
        sleeper.fireAll()
        await awaitHubCondition("the deferred run went") { runs.withLock { $0 } == 2 }
    }

    func testGitRefresherWaitsOnlyTheRestOfTheSpacingForADeferredChange() async {
        let sleeper = ManualSleeper()
        let clock = TestInstant()
        let refresher = gitRefresher(sleeper: sleeper, clock: clock)
        refresher.start()
        defer { refresher.stop() }
        await awaitHubCondition("the first pass ran") { sleeper.requested.count == 1 }

        clock.advance(by: .seconds(22))
        refresher.sessionStateChanged(workbenchID: 7)
        await awaitHubCondition("the loop waits for the deferred run") { sleeper.requested.count == 2 }
        XCTAssertEqual(sleeper.requested.last, .seconds(8))
    }

    /// A pass whose listing fails never reaches `takeDue`: the loop falls
    /// back to the idle wait rather than spinning on a stale due time.
    func testGitRefresherFallsBackToIdleAfterAFailedListing() async {
        let sleeper = ManualSleeper()
        let clock = TestInstant()
        let failing = OSAllocatedUnfairLock(initialState: false)
        let refresher = gitRefresher(sleeper: sleeper, clock: clock) {
            if failing.withLock({ $0 }) { throw CancellationError() }
            return [7]
        }
        refresher.start()
        defer { refresher.stop() }
        await awaitHubCondition("the first pass ran") { sleeper.requested.count == 1 }

        clock.advance(by: .seconds(22))
        refresher.sessionStateChanged(workbenchID: 7)
        await awaitHubCondition("the loop waits for the deferred run") { sleeper.requested.last == .seconds(8) }

        failing.withLock { $0 = true }
        clock.advance(by: .seconds(8))
        sleeper.fireAll()
        await awaitHubCondition("the failed pass waits idle") { sleeper.requested.count == 3 }
        XCTAssertEqual(sleeper.requested.last, .seconds(15))
    }

    /// Without a linked phone the loop lists nothing and still waits only
    /// once per idle interval.
    func testGitRefresherWithoutAPhoneWakesOncePerIdle() async {
        let sleeper = ManualSleeper()
        let checks = OSAllocatedUnfairLock(initialState: 0)
        let listings = OSAllocatedUnfairLock(initialState: 0)
        let refresher = WorkbenchGitRefresher(
            fetch: { WorkbenchGitStatus(workbenchID: $0) },
            workbenchIDs: {
                listings.withLock { $0 += 1 }
                return [7]
            },
            timing: .init(every: .seconds(120), minSpacing: .seconds(30), timeout: .seconds(5), idle: .seconds(15)),
            isActive: {
                checks.withLock { $0 += 1 }
                return false
            },
            wake: HubRunnerWake(sleep: sleeper.sleep)
        )
        refresher.start()
        defer { refresher.stop() }
        for round in 1...3 {
            await awaitHubCondition("idle wait \(round)") { sleeper.requested.count == round && sleeper.parkedCount == 1 }
            XCTAssertEqual(checks.withLock { $0 }, round)
            sleeper.fireAll()
        }
        XCTAssertTrue(sleeper.requested.allSatisfy { $0 == .seconds(15) })
        XCTAssertEqual(listings.withLock { $0 }, 0)
    }

    // MARK: - Report summary runner

    func testSummaryRunnerWakesOnAStateChangeAndCoalescesABurst() async {
        let sleeper = ManualSleeper()
        let clock = TestInstant()
        let listings = OSAllocatedUnfairLock(initialState: 0)
        let runs = OSAllocatedUnfairLock<[Int64]>(initialState: [])
        let summaries = SessionReportSummaryRunner(
            fetch: { id in
                runs.withLock { $0.append(id) }
                return []
            },
            workbenches: {
                listings.withLock { $0 += 1 }
                return .init(live: [], published: [7])
            },
            timing: .init(every: .seconds(60), minSpacing: .seconds(5), timeout: .seconds(5), idle: .seconds(15)),
            clock: { clock.now },
            wake: sleeper.wake(clock)
        )
        summaries.start()
        defer { summaries.stop() }
        await awaitHubCondition("the first pass ran and the loop waits idle") { sleeper.requested == [.seconds(15)] }
        XCTAssertEqual(runs.withLock { $0 }, [], "no live session, no request: nothing runs")

        clock.advance(by: .seconds(5))
        summaries.sessionStateChanged(workbenchID: 7)
        await awaitHubCondition("the change ran at once") { runs.withLock { $0 } == [7] }
        XCTAssertEqual(sleeper.fired, 0, "no timer ran out")
        await awaitHubCondition("the loop waits idle again") { sleeper.requested.count == 2 && sleeper.parkedCount == 1 }

        // A burst 1 s after that pass: one pass, after the rest of the gap.
        clock.advance(by: .seconds(1))
        summaries.sessionStateChanged(workbenchID: 7)
        summaries.sessionStateChanged(workbenchID: 7)
        await awaitHubCondition("the burst waits the rest of the gap") { sleeper.requested.last == .seconds(4) }
        XCTAssertEqual(runs.withLock { $0 }, [7])
        XCTAssertEqual(listings.withLock { $0 }, 2)

        clock.advance(by: .seconds(4))
        sleeper.fireAll()
        await awaitHubCondition("the burst ran once") { runs.withLock { $0 } == [7, 7] }
        await awaitHubCondition("then the loop idles") { sleeper.requested.last == .seconds(15) }
        XCTAssertEqual(listings.withLock { $0 }, 3)
    }

    // MARK: - Session report runner

    func testReportRunnerWakesOnAStateChangeAndAPhoneRequestAtOnce() async throws {
        let sleeper = ManualSleeper()
        let clock = TestInstant()
        let listings = OSAllocatedUnfairLock(initialState: 0)
        let runs = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let window: SessionReportRunner.Window = {
            listings.withLock { $0 += 1 }
            return [SessionReportSlice.Windowed(
                sessionID: 31, workbenchID: 7, live: false, createdAt: Date(), lastActiveAt: Date(),
                state: .init(kind: .stopped, live: false), stateAt: nil
            )]
        }
        let reports = SessionReportRunner(
            fetch: { _, _, network in
                runs.withLock { $0.append(network) }
                throw CancellationError()
            },
            sidecar: try HubSyncState.inMemory(),
            timing: .init(
                every: .seconds(120), stateSpacing: .seconds(5), requestSpacing: .seconds(60),
                timeout: .seconds(5), idle: .seconds(15)
            ),
            clock: { clock.now },
            wake: sleeper.wake(clock),
            window: window
        )
        reports.start()
        defer { reports.stop() }
        await awaitHubCondition("the first pass ran and the loop waits idle") { sleeper.requested == [.seconds(15)] }
        XCTAssertEqual(listings.withLock { $0 }, 1, "a start runs one pass, not two")
        XCTAssertEqual(runs.withLock { $0 }, [false], "the first sighting with no stored report runs once")

        clock.advance(by: .seconds(5))
        reports.sessionStatesChanged()
        await awaitHubCondition("the state change woke the loop") { listings.withLock { $0 } == 2 }

        clock.advance(by: .seconds(60))
        XCTAssertTrue(reports.requestReport(sessionID: 31))
        await awaitHubCondition("the phone request ran at once") { runs.withLock { $0 } == [false, true] }
        XCTAssertEqual(sleeper.fired, 0, "no timer ran out")
    }

    func testWithoutEventsTheReportRunnerPassesOncePerIdleWait() async throws {
        let sleeper = ManualSleeper()
        let listings = OSAllocatedUnfairLock(initialState: 0)
        let window: SessionReportRunner.Window = {
            listings.withLock { $0 += 1 }
            return []
        }
        let reports = SessionReportRunner(
            fetch: { _, _, _ in throw CancellationError() },
            sidecar: try HubSyncState.inMemory(),
            wake: HubRunnerWake(sleep: sleeper.sleep),
            window: window
        )
        reports.start()
        defer { reports.stop() }
        for round in 1...3 {
            await awaitHubCondition("idle wait \(round)") { sleeper.requested.count == round && sleeper.parkedCount == 1 }
            XCTAssertEqual(listings.withLock { $0 }, round, "one pass per idle wait")
            sleeper.fireAll()
        }
        XCTAssertTrue(sleeper.requested.allSatisfy { $0 == .seconds(15) })
    }

    // MARK: - Helpers

    private func gitRefresher(
        sleeper: ManualSleeper,
        clock: TestInstant,
        fetch: @escaping WorkbenchGitRefresher.Fetch = { WorkbenchGitStatus(workbenchID: $0) },
        workbenchIDs: @escaping @Sendable () async throws -> [Int64] = { [7] }
    ) -> WorkbenchGitRefresher {
        WorkbenchGitRefresher(
            fetch: fetch,
            workbenchIDs: workbenchIDs,
            timing: .init(every: .seconds(120), minSpacing: .seconds(30), timeout: .seconds(5), idle: .seconds(15)),
            clock: { clock.now },
            wake: sleeper.wake(clock)
        )
    }
}

/// A test clock for `HubRunnerWake`: each timed sleep records its duration
/// and parks until `fireAll()` (or its task's cancel). Recording and parking
/// happen in one locked step, so a test that sees a request can fire it.
final class ManualSleeper: Sendable {
    private struct State {
        var requested: [Duration] = []
        var fired = 0
        var parked: [Int: CheckedContinuation<Void, Never>] = [:]
        var nextID = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Every duration a sleep asked for, in order.
    var requested: [Duration] { state.withLock { $0.requested } }
    /// How many sleeps ran out (`fireAll`).
    var fired: Int { state.withLock { $0.fired } }
    /// The sleeps parked now.
    var parkedCount: Int { state.withLock { $0.parked.count } }

    var sleep: HubRunnerWake.Sleep {
        { [self] duration in await park(duration) }
    }

    /// A wake that sleeps on this sleeper and measures its gap on `clock`.
    func wake(_ clock: TestInstant) -> HubRunnerWake {
        HubRunnerWake(sleep: sleep, clock: { clock.now }) // swiftlint:disable:this trailing_closure
    }

    /// Ends every parked sleep.
    func fireAll() {
        let parked = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            defer { state.parked = [:] }
            state.fired += state.parked.count
            return Array(state.parked.values)
        }
        parked.forEach { $0.resume() }
    }

    private func park(_ duration: Duration) async {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let cancelled = state.withLock { state -> Bool in
                    if Task.isCancelled { return true }
                    state.requested.append(duration)
                    state.parked[id] = continuation
                    return false
                }
                if cancelled { continuation.resume() }
            }
        } onCancel: {
            let continuation = state.withLock { $0.parked.removeValue(forKey: id) }
            continuation?.resume()
        }
    }
}

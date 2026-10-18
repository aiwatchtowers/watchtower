import Foundation
import os
import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// Board #842 (owner decision ask #337): the hub's CLI runners wake on a
/// session state change (or a phone request) at once and otherwise at most
/// once per idle interval; the asks fast lane keeps its cadence.
final class HubRunnerWakeTests: XCTestCase {
    // MARK: - The wait

    func testASignalEndsAWaitInProgressAtOnce() async {
        let sleeper = ManualSleeper()
        let wake = HubRunnerWake(sleep: sleeper.sleep)
        let ended = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            await wake.wait(upTo: .seconds(15))
            ended.withLock { $0 = true }
        }
        await awaitHubCondition("the wait started its timer") { sleeper.requested == [.seconds(15)] }
        XCTAssertFalse(ended.withLock { $0 })

        wake.signal()
        await awaitHubCondition("the signal ended the wait") { ended.withLock { $0 } }
        XCTAssertEqual(sleeper.fired, 0, "the timer never ran out")
        await task.value
    }

    func testASignalSentBetweenWaitsEndsTheNextWaitAtOnce() async {
        let sleeper = ManualSleeper()
        let wake = HubRunnerWake(sleep: sleeper.sleep)
        wake.signal()
        await wake.wait(upTo: .seconds(15))
        XCTAssertEqual(sleeper.requested, [], "a pending signal takes no timer")

        // Taken once: the wait after it runs its timer.
        let task = Task { await wake.wait(upTo: .seconds(15)) }
        await awaitHubCondition("the next wait started its timer") { sleeper.requested == [.seconds(15)] }
        sleeper.fireAll()
        await task.value
    }

    func testWithoutASignalTheWaitEndsWhenItsTimerDoes() async {
        let sleeper = ManualSleeper()
        let wake = HubRunnerWake(sleep: sleeper.sleep)
        let ended = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            await wake.wait(upTo: .seconds(15))
            ended.withLock { $0 = true }
        }
        await awaitHubCondition("the wait started its timer") { sleeper.requested == [.seconds(15)] }
        await Task.yield()
        XCTAssertFalse(ended.withLock { $0 })

        sleeper.fireAll()
        await awaitHubCondition("the timer ended the wait") { ended.withLock { $0 } }
        await task.value
    }

    func testCancellingTheTaskEndsTheWait() async {
        let sleeper = ManualSleeper()
        let wake = HubRunnerWake(sleep: sleeper.sleep)
        let task = Task { await wake.wait(upTo: .seconds(15)) }
        await awaitHubCondition("the wait started its timer") { sleeper.requested.count == 1 }
        task.cancel()
        await task.value
        XCTAssertEqual(sleeper.fired, 0)
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
        let refresher = WorkbenchGitRefresher(
            fetch: { id in
                runs.withLock { $0 += 1 }
                return WorkbenchGitStatus(workbenchID: id, branch: "main", detached: false, changes: 0)
            },
            workbenchIDs: {
                listings.withLock { $0 += 1 }
                return [7]
            },
            timing: .init(every: .seconds(120), minSpacing: .seconds(30), timeout: .seconds(5), idle: .seconds(15)),
            clock: { clock.now },
            wake: HubRunnerWake(sleep: sleeper.sleep)
        )
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

        // A change inside the 30 s spacing wakes the loop at once; the pass
        // defers the run and the loop waits only until it is due.
        refresher.sessionStateChanged(workbenchID: 7)
        await awaitHubCondition("the change woke the loop") { listings.withLock { $0 } == 3 }
        await awaitHubCondition("the loop waits for the deferred run") { sleeper.requested.count == 3 }
        XCTAssertEqual(sleeper.requested.last, .seconds(10), "10 s of the 30 s spacing left")
        XCTAssertEqual(runs.withLock { $0 }, 1)
        XCTAssertEqual(sleeper.fired, 1, "only the first idle wait ran out")

        clock.advance(by: .seconds(10))
        sleeper.fireAll()
        await awaitHubCondition("the deferred run went") { runs.withLock { $0 } == 2 }
    }

    func testGitRefresherWaitsOnlyTheRestOfTheSpacingForADeferredChange() async {
        let sleeper = ManualSleeper()
        let clock = TestInstant()
        let refresher = WorkbenchGitRefresher(
            fetch: { WorkbenchGitStatus(workbenchID: $0, branch: "main", detached: false, changes: 0) },
            workbenchIDs: { [7] },
            timing: .init(every: .seconds(120), minSpacing: .seconds(30), timeout: .seconds(5), idle: .seconds(15)),
            clock: { clock.now },
            wake: HubRunnerWake(sleep: sleeper.sleep)
        )
        refresher.start()
        defer { refresher.stop() }
        await awaitHubCondition("the first pass ran") { sleeper.requested.count == 1 }

        clock.advance(by: .seconds(22))
        refresher.sessionStateChanged(workbenchID: 7)
        await awaitHubCondition("the loop waits for the deferred run") { sleeper.requested.count == 2 }
        XCTAssertEqual(sleeper.requested.last, .seconds(8))
    }

    // MARK: - Report summary runner

    func testSummaryRunnerWakesOnAStateChangeAtOnceAndOtherwiseOncePerIdle() async {
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
            wake: HubRunnerWake(sleep: sleeper.sleep)
        )
        summaries.start()
        defer { summaries.stop() }
        await awaitHubCondition("the first pass ran and the loop waits idle") { sleeper.requested == [.seconds(15)] }
        XCTAssertEqual(runs.withLock { $0 }, [], "no live session, no request: nothing runs")

        summaries.sessionStateChanged(workbenchID: 7)
        await awaitHubCondition("the change ran at once") { runs.withLock { $0 } == [7] }
        XCTAssertEqual(sleeper.fired, 0, "no timer ran out")

        // A second change inside the 5 s spacing: woken at once, deferred,
        // and the loop waits the rest of the spacing.
        clock.advance(by: .seconds(2))
        summaries.sessionStateChanged(workbenchID: 7)
        await awaitHubCondition("the loop waits for the deferred run") { sleeper.requested.last == .seconds(3) }
        XCTAssertEqual(runs.withLock { $0 }, [7])

        clock.advance(by: .seconds(3))
        sleeper.fireAll()
        await awaitHubCondition("the deferred run went") { runs.withLock { $0 } == [7, 7] }
        await awaitHubCondition("then the loop idles") { sleeper.requested.last == .seconds(15) }
        XCTAssertEqual(listings.withLock { $0 }, 4)
    }

    // MARK: - Session report runner

    func testReportRunnerWakesOnAStateChangeAndAPhoneRequestAtOnce() async throws {
        let sleeper = ManualSleeper()
        let clock = TestInstant()
        let listings = OSAllocatedUnfairLock(initialState: 0)
        let runs = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let sidecar = try HubSyncState.inMemory()
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
            sidecar: sidecar,
            timing: .init(
                every: .seconds(120), stateSpacing: .seconds(5), requestSpacing: .seconds(60),
                timeout: .seconds(5), idle: .seconds(15)
            ),
            clock: { clock.now },
            wake: HubRunnerWake(sleep: sleeper.sleep),
            window: window
        )
        reports.start()
        defer { reports.stop() }
        // `start()` itself reports a state change; its pass may take one
        // extra wake, after which the loop rests at idle.
        await awaitHubCondition("the loop waits idle") { sleeper.requested.last == .seconds(15) }
        let settled = listings.withLock { $0 }
        XCTAssertEqual(runs.withLock { $0 }, [false], "the first sighting with no stored report runs once")
        XCTAssertEqual(sleeper.fired, 0)

        reports.sessionStatesChanged()
        await awaitHubCondition("the state change woke the loop") { listings.withLock { $0 } == settled + 1 }

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
        await awaitHubCondition("the loop waits idle") { sleeper.requested.last == .seconds(15) }
        let settled = listings.withLock { $0 }
        let waits = sleeper.requested.count
        for round in 1...3 {
            sleeper.fireAll()
            await awaitHubCondition("idle wake \(round)") { sleeper.requested.count == waits + round }
            XCTAssertEqual(listings.withLock { $0 }, settled + round, "one pass per idle wait")
        }
        XCTAssertTrue(sleeper.requested.dropFirst(waits - 1).allSatisfy { $0 == .seconds(15) })
    }
}

/// A test clock for `HubRunnerWake`: each timed wait records its duration
/// and parks until `fireAll()` (or its task's cancel).
final class ManualSleeper: Sendable {
    private struct State {
        var requested: [Duration] = []
        var fired = 0
        var parked: [Int: CheckedContinuation<Void, Never>] = [:]
        var nextID = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Every duration a wait asked for, in order.
    var requested: [Duration] { state.withLock { $0.requested } }
    /// How many waits ran out (`fireAll`).
    var fired: Int { state.withLock { $0.fired } }

    var sleep: HubRunnerWake.Sleep {
        { [self] duration in await park(duration) }
    }

    /// Ends every parked timer.
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
            state.requested.append(duration)
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let cancelled = state.withLock { state -> Bool in
                    if Task.isCancelled { return true }
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

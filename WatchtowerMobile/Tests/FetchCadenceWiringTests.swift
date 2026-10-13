import SwiftUI
import UIKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The phone fetches when something changed (board #724, owner decision
/// Q1): a 60 s safety poll on every tab that pauses whenever the app is not
/// active, a return to the foreground that fetches unless the last fetch is
/// seconds old (then only a local apply), pushes fetched at once with the
/// light depth (the zone poll only on a foreground push's fallback), and
/// one follow-up for pushes that land during a fetch. The sleeper, the clock
/// and the CloudKit reach are all stepped by hand: no wall-clock wait
/// decides anything.
@MainActor
final class FetchCadenceWiringTests: XCTestCase {
    private struct Wired {
        let env: AppEnvironment
        let sleeper: TickSleeper
        let clock: MutableClock
        let remote: RemoteFetchRecorder
        let counter: EnergyCounter
    }

    /// A booted demo environment whose safety poll waits on its first sleep.
    private func makeWired() async throws -> Wired {
        let sleeper = TickSleeper()
        let clock = MutableClock()
        let remote = RemoteFetchRecorder()
        let counter = EnergyCounter(defaults: try makeDefaults())
        let env = try AppEnvironment(
            transport: InMemoryCloudTransport(),
            replicaPath: try makeReplicaPath(),
            transportKind: .inMemoryDemo,
            defaults: try makeDefaults(),
            recordingsDirectory: try makeRecordingsDirectory(),
            now: { clock.now },
            remoteFetch: { try await remote.fetch($0) },
            sleep: { try await sleeper.sleep($0) },
            energy: counter
        )
        addTeardownBlock { @MainActor in env.stop() }
        try await poll({ env.isLooping && sleeper.waitingCount == 1 }, "the boot did not start the safety poll")
        return Wired(env: env, sleeper: sleeper, clock: clock, remote: remote, counter: counter)
    }

    // MARK: - Safety poll

    func testTheSafetyPollRunsEveryMinuteOnEveryTab() async throws {
        let wired = try await makeWired()
        XCTAssertEqual(AppEnvironment.safetyPollInterval, .seconds(60))
        XCTAssertEqual(wired.sleeper.requested, [.seconds(60)])
        XCTAssertEqual(wired.remote.depths, [.full], "the launch fetch only: no poll right behind it")

        for tab in RootTabView.Tab.allCases {
            wired.env.navigation.tab = tab
        }
        wired.sleeper.tick()
        try await poll({ wired.remote.depths.count == 2 && wired.sleeper.waitingCount == 1 }, "a tick is one fetch")
        XCTAssertEqual(wired.remote.depths, [.full, .full], "the safety poll keeps the zone poll's guarantee")
        XCTAssertEqual(wired.sleeper.requested, [.seconds(60), .seconds(60)], "the tab sets no cadence")
        XCTAssertEqual(wired.counter.counts(daysAgo: 0)[.fetchLoop], 1)
    }

    func testInactiveAndBackgroundPauseThePoll() async throws {
        let wired = try await makeWired()
        XCTAssertFalse(RootTabView.isActive(in: .inactive))
        XCTAssertFalse(RootTabView.isActive(in: .background))

        for phase in [ScenePhase.inactive, .background] {
            wired.env.setActive(RootTabView.isActive(in: phase))
            XCTAssertFalse(wired.env.isLooping)
            try await poll({ wired.sleeper.waitingCount == 0 }, "the paused poll's sleep is cancelled")
            let fetched = wired.remote.depths.count
            wired.sleeper.tick()
            await Task.yield()
            XCTAssertEqual(wired.remote.depths.count, fetched, "no fetch while \(phase)")
            wired.env.setActive(true)
            try await poll { wired.sleeper.waitingCount == 1 }
        }
    }

    // MARK: - Return to the foreground

    func testTheReturnToTheForegroundFetchesUnlessTheLastFetchIsRecent() async throws {
        let wired = try await makeWired()

        // A Control Center peek: the launch fetch is seconds old.
        wired.env.setActive(false)
        wired.clock.advance(AppEnvironment.foregroundRefetchAfter - 1)
        wired.env.setActive(true)
        XCTAssertTrue(wired.env.isLooping)
        try await poll { wired.sleeper.waitingCount == 1 }
        XCTAssertEqual(wired.remote.depths, [.full], "a peek costs no fetch")

        wired.env.setActive(false)
        wired.clock.advance(AppEnvironment.foregroundRefetchAfter + 1)
        wired.env.setActive(true)
        try await poll({ wired.remote.depths.count == 2 && wired.sleeper.waitingCount == 1 }, "the return fetches at once")
        XCTAssertEqual(wired.remote.depths.last, .full)
        XCTAssertEqual(wired.counter.counts(daysAgo: 0)[.fetchForeground], 1)
    }

    // MARK: - Pushes

    func testAForegroundPushFetchesAtOnceWithTheLightDepthAndRestartsThePoll() async throws {
        let wired = try await makeWired()
        wired.clock.advance(30)
        let pushedAt = wired.clock.now

        let outcome = await wired.env.handlePush(inForeground: true)

        XCTAssertEqual(outcome, .noData, "nothing new arrived")
        XCTAssertEqual(
            wired.remote.depths, [.full, .push(since: pushedAt, pollOnFallback: true)],
            "the light depth; only its fallback polls the zones"
        )
        try await poll({ wired.sleeper.requested.count == 2 && wired.sleeper.waitingCount == 1 },
                       "the safety poll restarts from the push fetch")
        XCTAssertEqual(wired.counter.counts(daysAgo: 0)[.fetchPush], 1)
        XCTAssertEqual(wired.counter.counts(daysAgo: 0)[.fetchLoop], 0)
    }

    func testAFailedPushFetchReportsFailed() async throws {
        let wired = try await makeWired()
        wired.remote.failing = true

        let outcome = await wired.env.handlePush(inForeground: true)

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(FetchOutcome.failed.backgroundFetchResult, .failed)
        XCTAssertEqual(FetchOutcome.newData.backgroundFetchResult, .newData)
        XCTAssertEqual(FetchOutcome.noData.backgroundFetchResult, .noData)
    }

    func testABackgroundPushIsFetchedAtOnceWithTheLightFetchAndNoPoll() async throws {
        let wired = try await makeWired()
        wired.env.setActive(false)
        try await poll { wired.sleeper.waitingCount == 0 }
        let requested = wired.sleeper.requested.count
        wired.clock.advance(30)
        let pushedAt = wired.clock.now

        let outcome = await wired.env.handlePush(inForeground: false)

        XCTAssertEqual(outcome, .noData)
        XCTAssertEqual(
            wired.remote.depths, [.full, .push(since: pushedAt, pollOnFallback: false)],
            "fetched at once, and its fallback stays light"
        )
        XCTAssertEqual(wired.sleeper.requested.count, requested, "nothing waits before the fetch")
        XCTAssertFalse(wired.env.isLooping, "a background push starts no safety poll")
    }

    func testABackgroundPushBurstSharesOneFetchAndEveryPushIsAnswered() async throws {
        let wired = try await makeWired()
        wired.env.setActive(false)
        try await poll { wired.sleeper.waitingCount == 0 }
        wired.remote.holding = true

        let first = Task { await wired.env.handlePush(inForeground: false) }
        try await poll({ wired.remote.heldCount == 1 }, "the first push is fetched at once")
        let more = (0..<2).map { _ in Task { await wired.env.handlePush(inForeground: false) } }
        try await poll({ wired.env.followUpWaiters == 2 }, "the pushes during the fetch wait for one follow-up")
        XCTAssertEqual(wired.remote.pushCount, 1)
        wired.remote.release()
        var outcomes = [await first.value]
        for push in more {
            outcomes.append(await push.value)
        }

        XCTAssertEqual(outcomes, [.noData, .noData, .noData], "every push gets its completion")
        XCTAssertEqual(wired.remote.pushCount, 2, "three pushes: the fetch and one follow-up")
        XCTAssertEqual(wired.counter.counts(daysAgo: 0)[.fetchPush], 2)
        XCTAssertFalse(wired.env.isLooping, "a background push starts no safety poll")
    }

    func testAPushDuringARunningFetchGetsExactlyOneFollowUp() async throws {
        let wired = try await makeWired()
        wired.remote.holding = true
        let pull = Task { await wired.env.refresh(.pull) }
        try await poll({ wired.remote.heldCount == 1 }, "the pull is not running")

        let pushes = (0..<3).map { _ in Task { await wired.env.handlePush(inForeground: true) } }
        try await poll({ wired.env.followUpWaiters == 3 }, "every push waits for the follow-up")
        XCTAssertEqual(wired.remote.pushCount, 0, "the follow-up waits for the running fetch")
        wired.remote.release()
        _ = await pull.value
        var outcomes: [FetchOutcome] = []
        for push in pushes {
            outcomes.append(await push.value)
        }

        XCTAssertEqual(outcomes.count, 3)
        XCTAssertEqual(wired.remote.pushCount, 1, "one follow-up, not one per push")
        XCTAssertEqual(wired.remote.fullCount, 2, "the launch and the pull")
    }

    func testAFetchBegunAfterAPushServesIt() async throws {
        let wired = try await makeWired()
        wired.env.setActive(false)
        try await poll { wired.sleeper.waitingCount == 0 }
        wired.remote.holding = true
        let pull = Task { await wired.env.refresh(.pull) }
        try await poll({ wired.remote.heldCount == 1 }, "the pull is not running")
        let push = Task { await wired.env.handlePush(inForeground: false) }
        try await poll({ wired.env.followUpWaiters == 1 }, "the push waits behind the pull")

        // The link flow (say) begins a fetch after the push arrived.
        let link = Task { await wired.env.refresh(.link) }
        try await poll({ wired.remote.heldCount == 2 }, "the link fetch is not running")
        wired.remote.release()
        _ = await pull.value
        _ = await link.value
        _ = await push.value

        XCTAssertEqual(wired.remote.pushCount, 0, "the later full fetch already covered the push")
        XCTAssertEqual(wired.remote.fullCount, 3, "the launch, the pull and the link fetch")
    }

    func testAQuickReturnAppliesWhatTheEngineBufferedWithoutFetching() async throws {
        let wired = try await makeWired()
        var applied = 0
        wired.env.onFetched = { applied += 1 }

        wired.env.setActive(false)
        wired.clock.advance(AppEnvironment.foregroundRefetchAfter - 1)
        wired.env.setActive(true)

        try await poll({ applied == 1 }, "the quick return applies the buffered changes")
        XCTAssertEqual(wired.remote.depths, [.full], "and reaches no network")
    }
}

/// Stands in for an environment's CloudKit reach (`remoteFetch`): records
/// each fetch's depth, can hold fetches until `release()`, and can fail.
@MainActor
final class RemoteFetchRecorder {
    struct Failure: Error {}

    private(set) var depths: [RemoteFetchDepth] = []
    /// While true, each fetch waits for `release()`.
    var holding = false
    /// While true, each fetch throws.
    var failing = false
    private var held: [CheckedContinuation<Void, Never>] = []

    var heldCount: Int { held.count }
    var pushCount: Int { depths.filter { if case .push = $0 { true } else { false } }.count }
    var fullCount: Int { depths.filter { $0 == .full }.count }

    func fetch(_ depth: RemoteFetchDepth) async throws {
        depths.append(depth)
        if holding {
            await withCheckedContinuation { held.append($0) }
        }
        if failing { throw Failure() }
    }

    /// Stops holding and lets every held fetch go on.
    func release() {
        holding = false
        let all = held
        held = []
        all.forEach { $0.resume() }
    }
}

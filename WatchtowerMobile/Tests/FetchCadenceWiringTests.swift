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
        let env: HubSession
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
        let env = try HubSession(
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
        XCTAssertEqual(SessionCadence.safetyPollInterval, .seconds(60))
        XCTAssertEqual(wired.sleeper.requested, [.seconds(60)])
        XCTAssertEqual(wired.remote.depths, [.full], "the launch fetch only: no poll right behind it")

        let app = AppEnvironment.single(wired.env, defaults: try makeDefaults())
        for tab in RootTabView.Tab.allCases {
            app.navigation.tab = tab
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
        wired.clock.advance(SessionCadence.foregroundRefetchAfter(role: .active) - 1)
        wired.env.setActive(true)
        XCTAssertTrue(wired.env.isLooping)
        try await poll { wired.sleeper.waitingCount == 1 }
        XCTAssertEqual(wired.remote.depths, [.full], "a peek costs no fetch")

        wired.env.setActive(false)
        wired.clock.advance(SessionCadence.foregroundRefetchAfter(role: .active) + 1)
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
        wired.clock.advance(SessionCadence.foregroundRefetchAfter(role: .active) - 1)
        wired.env.setActive(true)

        try await poll({ applied == 1 }, "the quick return applies the buffered changes")
        XCTAssertEqual(wired.remote.depths, [.full], "and reaches no network")
    }

    // MARK: - Engine-run apply during a fetch

    func testAnApplySkippedDuringAFetchThatFailsLandsAfterIt() async throws {
        let wired = try await makeWired()
        var applied = 0
        wired.env.onFetched = { applied += 1 }
        wired.remote.holding = true
        wired.remote.failing = true
        let pull = Task { await wired.env.refresh(.pull) }
        try await poll({ wired.remote.heldCount == 1 }, "the pull is not running")

        await wired.env.applyBuffered()
        XCTAssertEqual(applied, 0, "skipped while the fetch waits on CloudKit")
        wired.remote.release()
        let fetched = await pull.value

        XCTAssertFalse(fetched)
        XCTAssertEqual(applied, 1, "the failed fetch runs the skipped apply")
    }

    func testAnApplySkippedDuringAFetchThatSucceedsIsCoveredByIt() async throws {
        let wired = try await makeWired()
        var applied = 0
        wired.env.onFetched = { applied += 1 }
        wired.remote.holding = true
        let pull = Task { await wired.env.refresh(.pull) }
        try await poll({ wired.remote.heldCount == 1 }, "the pull is not running")

        await wired.env.applyBuffered()
        wired.remote.release()
        _ = await pull.value

        XCTAssertEqual(applied, 1, "the fetch's own hydrate, no second apply")
    }

    // MARK: - Push completion deadline

    func testAPushWhoseFetchEndsFirstCompletesOnce() async throws {
        let wired = try await makeWired()
        let deadline = TickSleeper()
        var completions: [FetchOutcome] = []

        PushCompletion.race(
            sleep: { try await deadline.sleep($0) },
            fetch: { await wired.env.handlePush(inForeground: false) },
            outcomeAtDeadline: { .failed },
            completion: { completions.append($0) }
        )
        try await poll({ completions.count == 1 }, "the fetch never completed the push")
        try await poll({ deadline.waitingCount == 0 }, "the deadline was not cancelled")
        deadline.tick()

        XCTAssertEqual(deadline.requested, [PushCompletion.deadline])
        XCTAssertEqual(completions, [.noData], "the fetch's outcome, exactly once")
    }

    func testAPushPastTheDeadlineCompletesOnceAndTheFetchGoesOn() async throws {
        let wired = try await makeWired()
        let deadline = TickSleeper()
        let tasks = FakeBackgroundTasks()
        var completions: [FetchOutcome] = []
        wired.remote.holding = true

        PushCompletion.serve(
            AppEnvironment.single(wired.env, defaults: try makeDefaults()), arrivedAt: wired.clock.now, inForeground: false,
            startWork: BackgroundWork.starter(runner: tasks, suspension: DatabaseSuspension { _ in }) { true },
            sleep: { try await deadline.sleep($0) },
            completion: { completions.append($0) }
        )
        try await poll({ wired.remote.heldCount == 1 && deadline.waitingCount == 1 }, "the race did not start")
        deadline.tick()
        try await poll({ completions.count == 1 }, "the deadline never completed the push")
        XCTAssertEqual(completions, [.noData])
        XCTAssertTrue(tasks.ended.isEmpty, "the work outlives the completion")
        wired.remote.release()
        try await poll({ tasks.ended.count == 1 }, "the fetch was dropped at the deadline")

        XCTAssertEqual(completions, [.noData], "the late fetch completes nothing")
    }

    /// The deadline reports the push's own state, not an unrelated fetch's:
    /// a pull that failed before the push does not turn it into `.failed`.
    func testThePushDeadlineIgnoresAnUnrelatedFailedFetch() async throws {
        let wired = try await makeWired()
        wired.remote.failing = true
        let pulled = await wired.env.refresh(.pull)
        XCTAssertFalse(pulled)
        wired.remote.failing = false
        let deadline = TickSleeper()
        var completions: [FetchOutcome] = []
        wired.remote.holding = true

        PushCompletion.serve(
            AppEnvironment.single(wired.env, defaults: try makeDefaults()), arrivedAt: wired.clock.now, inForeground: false,
            startWork: BackgroundWork.starter(runner: FakeBackgroundTasks(), suspension: DatabaseSuspension { _ in }) { true },
            sleep: { try await deadline.sleep($0) },
            completion: { completions.append($0) }
        )
        try await poll({ wired.remote.heldCount == 1 && deadline.waitingCount == 1 }, "the race did not start")
        deadline.tick()
        try await poll({ completions.count == 1 }, "the deadline never completed the push")
        wired.remote.release()

        XCTAssertEqual(completions, [.noData])
    }

    /// The push's arrival, stamped by the app delegate before any hop, is
    /// the `since` its light fetch is covered from.
    func testThePushIsCoveredFromItsArrivalStamp() async throws {
        let wired = try await makeWired()
        let arrivedAt = wired.clock.now
        wired.clock.advance(3)

        _ = await wired.env.handlePush(at: arrivedAt, inForeground: false)

        XCTAssertEqual(wired.remote.depths.last, .push(since: arrivedAt, pollOnFallback: false))
    }

    // MARK: - Launch into the background (board #724)

    /// A demo environment built in the background (`startsActive: false`)
    /// whose CloudKit reach is held until released.
    private func makeBackgroundLaunch() throws -> Wired {
        let sleeper = TickSleeper()
        let clock = MutableClock()
        let remote = RemoteFetchRecorder()
        remote.holding = true
        let counter = EnergyCounter(defaults: try makeDefaults())
        let env = try HubSession(
            transport: InMemoryCloudTransport(),
            replicaPath: try makeReplicaPath(),
            transportKind: .inMemoryDemo,
            defaults: try makeDefaults(),
            recordingsDirectory: try makeRecordingsDirectory(),
            startsActive: false,
            uploadRetriesAllowed: false,
            now: { clock.now },
            remoteFetch: { try await remote.fetch($0) },
            sleep: { try await sleeper.sleep($0) },
            energy: counter
        )
        addTeardownBlock { @MainActor in
            env.stop()
            remote.release()
        }
        return Wired(env: env, sleeper: sleeper, clock: clock, remote: remote, counter: counter)
    }

    /// Built in the background: no safety poll after the boot or after a
    /// push; the scene's first active phase makes it active and starts the
    /// poll with a full fetch.
    func testAnEnvironmentBuiltInTheBackgroundPollsOnlyOnceActive() async throws {
        let launch = try makeBackgroundLaunch()
        let (env, sleeper, remote) = (launch.env, launch.sleeper, launch.remote)
        XCTAssertFalse(env.isActive)
        try await poll({ remote.heldCount == 1 }, "the launch fetch never began")
        XCTAssertEqual(remote.depths, [.full], "no push: the launch keeps the full reach")
        remote.holding = false
        remote.release()
        await env.waitForBoot()
        XCTAssertTrue(env.isBootstrapped)
        XCTAssertFalse(env.isLooping, "no poll after a background boot")

        _ = await env.handlePush(inForeground: false)
        XCTAssertFalse(env.isLooping, "no poll after a background push")
        XCTAssertEqual(sleeper.requested, [], "nothing ever waited on the poll")

        env.setActive(RootTabView.isActive(in: .active))
        XCTAssertTrue(env.isActive)
        XCTAssertTrue(env.isLooping)
        try await poll({ sleeper.waitingCount == 1 }, "the poll never started")
    }

    /// A push that arrives before the boot has started the transport: it
    /// waits for the launch fetch, which serves it with the light reach (no
    /// forced zone poll); the push gets that outcome, and its work ends
    /// only once the boot has ended. The first activation fetches in full.
    func testAPushBeforeTheBootIsServedByALightLaunchFetch() async throws {
        let tasks = FakeBackgroundTasks()
        let suspension = DatabaseSuspension { _ in }
        let launch = try makeBackgroundLaunch()
        let (env, sleeper, clock, remote, counter) = (launch.env, launch.sleeper, launch.clock, launch.remote, launch.counter)
        let arrivedAt = clock.now
        var completions: [FetchOutcome] = []
        PushCompletion.serve(
            AppEnvironment.single(env, defaults: try makeDefaults()), arrivedAt: arrivedAt, inForeground: false,
            startWork: BackgroundWork.starter(runner: tasks, suspension: suspension) { true },
            sleep: { _ in try await Task.sleep(for: .seconds(86_400)) },
            completion: { completions.append($0) }
        )
        XCTAssertEqual(tasks.begun, ["silent-push-fetch"])

        try await poll({ remote.heldCount == 1 }, "the launch fetch never began")
        XCTAssertEqual(remote.depths, [.push(since: arrivedAt, pollOnFallback: false)],
                       "one light fetch serves the launch and the push")
        remote.release()
        try await poll({ completions == [.newData] }, "the push did not get the launch fetch's outcome")
        await env.waitForBoot()
        try await poll({ tasks.ended.count == 1 }, "the push's work never ended")
        XCTAssertTrue(env.isBootstrapped)
        XCTAssertEqual(counter.counts(daysAgo: 0)[.fetchLaunch], 1)
        XCTAssertEqual(counter.counts(daysAgo: 0)[.fetchPush] ?? 0, 0, "the push rode the launch fetch")
        XCTAssertFalse(env.isLooping)

        // Opened within seconds: the light launch owes a full fetch.
        clock.advance(1)
        remote.holding = false
        env.setActive(true)
        try await poll({ remote.fullCount == 1 && sleeper.waitingCount == 1 }, "the first activation did not fetch in full")
    }

    /// A push launch whose scene turns active while the boot still runs:
    /// the activation cannot start the loop yet, so the boot's end starts
    /// it with the owed full fetch at once, not a poll interval later.
    func testAnActivationDuringAPushLaunchBootFetchesInFullRightAfterTheBoot() async throws {
        let tasks = FakeBackgroundTasks()
        let suspension = DatabaseSuspension { _ in }
        let launch = try makeBackgroundLaunch()
        let (env, sleeper, clock, remote) = (launch.env, launch.sleeper, launch.clock, launch.remote)
        let arrivedAt = clock.now
        var completions: [FetchOutcome] = []
        PushCompletion.serve(
            AppEnvironment.single(env, defaults: try makeDefaults()), arrivedAt: arrivedAt, inForeground: false,
            startWork: BackgroundWork.starter(runner: tasks, suspension: suspension) { true },
            sleep: { _ in try await Task.sleep(for: .seconds(86_400)) },
            completion: { completions.append($0) }
        )
        try await poll({ remote.heldCount == 1 }, "the launch fetch never began")
        XCTAssertEqual(remote.depths, [.push(since: arrivedAt, pollOnFallback: false)])

        // Activated during the boot, while the light launch fetch is held.
        clock.advance(1)
        env.setActive(true)
        XCTAssertFalse(env.isBootstrapped)
        XCTAssertEqual(remote.fullCount, 0, "nothing fetches before the boot ends")

        remote.release()
        await env.waitForBoot()
        try await poll({ remote.fullCount == 1 && sleeper.waitingCount == 1 }, "the owed full fetch did not run after the boot")
        XCTAssertEqual(remote.depths.last, .full, "the owed fetch takes the full reach (with the zone poll)")
        XCTAssertEqual(sleeper.requested.count, 1, "the full fetch did not wait on a poll interval")
        try await poll({ completions == [.newData] }, "the push did not get the launch fetch's outcome")
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

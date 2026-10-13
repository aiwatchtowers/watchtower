import CloudKit
import XCTest
@testable import WatchtowerSync

/// The phone's push fetch (board #724): CKSyncEngine fetches on a push by
/// itself, so `fetchForPush` waits for that own run instead of fetching a
/// second time, and fetches through the engine itself — never with the
/// forced zone poll — only when no run begins within the grace. The
/// engine's run events are delivered by calling the transport's
/// `engineWillFetch()`/`engineDidFetch()` (the fake delivers no events).
final class CloudKitTransportPushFetchTests: XCTestCase {
    private let owner = "_acme-owner-record"
    private var shared: CloudDatabaseScope { .shared(ownerName: owner) }
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "push-fetch-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private func phone(
        engine: FakeSyncEngine,
        clock: TestClock = TestClock(),
        sleep: (@Sendable (TimeInterval) async -> Void)? = nil,
        energy: EnergyCounter? = nil
    ) async throws -> CloudKitTransport {
        await CloudKitTransport.testing(
            store: try .inMemory(), scope: shared, engine: engine, clock: clock, sleep: sleep, energy: energy
        )
    }

    /// Waits (bounded) until `count` push fetches wait on the engine's run.
    private func waitForWaiters(_ transport: CloudKitTransport, count: Int = 1) async throws {
        try await eventually { await transport.engineRunWaiterCount >= count }
        let waiting = await transport.engineRunWaiterCount
        XCTAssertEqual(waiting, count, "the push fetch never waited on the engine's run")
    }

    /// Waits (bounded, 5 s of wall clock) until `condition` holds.
    private func eventually(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let met = await condition()
        XCTAssertTrue(met, "condition not met in time")
    }

    func testWithoutAnEngineRunAPushFetchesThroughTheEngineWithoutTheZonePoll() async throws {
        let engine = FakeSyncEngine()
        let counter = EnergyCounter(defaults: defaults)
        let clock = TestClock()
        let transport = try await phone(engine: engine, clock: clock, energy: counter)

        try await transport.fetchForPush(since: clock.now, grace: 2)

        XCTAssertEqual(engine.fetchCount, 1, "the light fetch is the engine fetch")
        XCTAssertEqual(engine.zoneFetches, [], "a push never runs the forced zone poll")
        let today = counter.counts(daysAgo: 0)
        XCTAssertEqual(today[.engineFetch], 1)
        XCTAssertEqual(today[.dataZonePoll], 0)
        XCTAssertEqual(today[.relayZonePoll], 0)
    }

    func testAnEngineRunThatBeganAfterThePushCoversIt() async throws {
        let engine = FakeSyncEngine()
        let clock = TestClock()
        let transport = try await phone(engine: engine, clock: clock)
        let pushedAt = clock.now

        await transport.engineWillFetch()
        await transport.engineDidFetch()
        try await transport.fetchForPush(since: pushedAt, grace: 2)

        XCTAssertEqual(engine.fetchCount, 0, "the engine's own run already fetched this push")
        XCTAssertEqual(engine.zoneFetches, [])
        let covered = await transport.pushFetchesCoveredByEngine
        XCTAssertEqual(covered, 1)
    }

    func testARunningEngineRunIsAwaitedNotDuplicated() async throws {
        let engine = FakeSyncEngine()
        let clock = TestClock()
        let gate = Gate()
        let transport = try await phone(engine: engine, clock: clock) { _ in await gate.wait() }
        let pushedAt = clock.now
        await transport.engineWillFetch()

        let push = Task { try await transport.fetchForPush(since: pushedAt, grace: 2) }
        try await waitForWaiters(transport)
        XCTAssertEqual(engine.fetchCount, 0)
        await transport.engineDidFetch()
        try await push.value
        await gate.open()

        XCTAssertEqual(engine.fetchCount, 0, "the push shares the engine's run")
        let covered = await transport.pushFetchesCoveredByEngine
        XCTAssertEqual(covered, 1)
    }

    func testARunBeginningWithinTheGraceCoversThePush() async throws {
        let engine = FakeSyncEngine()
        let clock = TestClock()
        let gate = Gate()
        let transport = try await phone(engine: engine, clock: clock) { _ in await gate.wait() }
        let pushedAt = clock.now

        let push = Task { try await transport.fetchForPush(since: pushedAt, grace: 2) }
        try await waitForWaiters(transport)
        await transport.engineWillFetch()
        await transport.engineDidFetch()
        try await push.value
        await gate.open()

        XCTAssertEqual(engine.fetchCount, 0, "the engine's run, begun inside the grace, fetched the push")
    }

    func testARunThatBeganBeforeThePushDoesNotCoverIt() async throws {
        let engine = FakeSyncEngine()
        let clock = TestClock()
        let transport = try await phone(engine: engine, clock: clock)
        await transport.engineWillFetch()
        await transport.engineDidFetch()
        clock.advance(1)

        try await transport.fetchForPush(since: clock.now, grace: 2)

        XCTAssertEqual(engine.fetchCount, 1, "an earlier run says nothing about this push")
        XCTAssertEqual(engine.zoneFetches, [])
    }

    func testAPushWhoseGraceHasPassedFetchesAtOnce() async throws {
        let engine = FakeSyncEngine()
        let clock = TestClock()
        let sleeps = Collector<TimeInterval>()
        let transport = await CloudKitTransport.testing(
            store: try .inMemory(), scope: shared, engine: engine, clock: clock, sleeps: sleeps
        )
        let pushedAt = clock.now
        clock.advance(10)

        try await transport.fetchForPush(since: pushedAt, grace: 2)

        XCTAssertEqual(engine.fetchCount, 1)
        XCTAssertEqual(sleeps.values, [], "nothing waits once the grace is over")
    }

    func testAPushJoinsARunningPushFetch() async throws {
        let engine = FakeSyncEngine()
        let clock = TestClock()
        let gate = Gate()
        let transport = try await phone(engine: engine, clock: clock) { _ in await gate.wait() }
        let pushedAt = clock.now

        let first = Task { try await transport.fetchForPush(since: pushedAt, grace: 2) }
        try await waitForWaiters(transport)
        let second = Task { try await transport.fetchForPush(since: pushedAt, grace: 2) }
        try await eventually { await transport.pushFetchJoins >= 1 }
        let joins = await transport.pushFetchJoins
        XCTAssertEqual(joins, 1, "the second push never joined the first")
        await gate.open()
        try await first.value
        try await second.value

        XCTAssertEqual(engine.fetchCount, 1, "two pushes, one fetch")
    }

    func testAPullDuringThePushsWaitServesThePushAndNeverWaitsOnTheEngine() async throws {
        let engine = FakeSyncEngine()
        let clock = TestClock()
        let gate = Gate()
        let transport = try await phone(engine: engine, clock: clock) { _ in await gate.wait() }

        let push = Task { try await transport.fetchForPush(since: clock.now, grace: 2) }
        try await waitForWaiters(transport)
        // The grace's sleeper never ends here: the pull must not wait on it.
        try await transport.pull()
        try await push.value
        await gate.open()

        XCTAssertEqual(engine.fetchCount, 1, "the pull's fetch is the push's")
        XCTAssertEqual(engine.zoneFetches.count, CloudZoneID.allCases.count, "the pull polls")
    }

    func testAPullStillPollsAfterAPushsOwnRunningFetch() async throws {
        let engine = FakeSyncEngine()
        let clock = TestClock()
        let fetchGate = Gate()
        let transport = try await phone(engine: engine, clock: clock)
        engine.onNextFetch { await fetchGate.wait() }
        let pushedAt = clock.now
        clock.advance(10)

        // The grace has passed: the push fetches at once, held in the engine.
        let push = Task { try await transport.fetchForPush(since: pushedAt, grace: 2) }
        try await eventually { engine.fetchCount >= 1 }
        let pull = Task { try await transport.pull() }
        await fetchGate.open()
        try await push.value
        try await pull.value

        XCTAssertEqual(engine.fetchCount, 2, "the push's light fetch, then the pull's own")
        XCTAssertEqual(engine.zoneFetches.count, CloudZoneID.allCases.count, "only the pull polls")
    }

    func testAnEngineRunThatNeverEndsStallsNothing() async throws {
        let engine = FakeSyncEngine()
        let clock = TestClock()
        let sleepGate = Gate()
        let requested = Collector<TimeInterval>()
        let transport = try await phone(engine: engine, clock: clock) { seconds in
            requested.append(seconds)
            await sleepGate.wait()
        }
        let pushedAt = clock.now
        await transport.engineWillFetch()

        let push = Task { try await transport.fetchForPush(since: pushedAt, grace: 2) }
        try await waitForWaiters(transport)
        try await eventually { !requested.values.isEmpty }
        XCTAssertEqual(requested.values, [CloudKitTransport.engineRunEndWait(grace: 2)])
        XCTAssertEqual(CloudKitTransport.engineRunEndWait(grace: 2), 30)
        // The end wait's bound passes with no didFetchChanges.
        await sleepGate.open()
        try await push.value

        XCTAssertEqual(engine.fetchCount, 1, "the push falls back to its own fetch")
        let covered = await transport.pushFetchesCoveredByEngine
        XCTAssertEqual(covered, 0)
        try await transport.pull()
        XCTAssertEqual(engine.fetchCount, 2, "a pull afterwards is not blocked")
    }

    func testAForegroundPushsFallbackPollsTheZones() async throws {
        let engine = FakeSyncEngine()
        let clock = TestClock()
        let transport = try await phone(engine: engine, clock: clock)
        let pushedAt = clock.now
        clock.advance(10)

        try await transport.fetchForPush(since: pushedAt, grace: 2, pollOnFallback: true)

        XCTAssertEqual(engine.fetchCount, 1)
        XCTAssertEqual(engine.zoneFetches.count, CloudZoneID.allCases.count, "the fallback reaches every zone")
    }

    func testARunThatEndsBeforeTheBoundStopsTheTimer() async throws {
        let engine = FakeSyncEngine()
        let clock = TestClock()
        let timers = Collector<Bool>()
        let transport = try await phone(engine: engine, clock: clock) { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            timers.append(Task.isCancelled)
        }
        let pushedAt = clock.now

        let push = Task { try await transport.fetchForPush(since: pushedAt, grace: 2) }
        try await waitForWaiters(transport)
        await transport.engineWillFetch()
        await transport.engineDidFetch()
        try await push.value
        try await eventually { !timers.values.isEmpty }

        XCTAssertFalse(timers.values.isEmpty)
        XCTAssertFalse(timers.values.contains(false), "every wait's timer is cancelled once its wait ended")
        XCTAssertEqual(engine.fetchCount, 0)
    }

    func testStoppingReleasesAWaitingPushFetch() async throws {
        let engine = FakeSyncEngine()
        let clock = TestClock()
        let gate = Gate()
        let transport = try await phone(engine: engine, clock: clock) { _ in await gate.wait() }

        let push = Task { try await transport.fetchForPush(since: clock.now, grace: 2) }
        try await waitForWaiters(transport)
        await transport.stop()
        try await push.value
        await gate.open()

        XCTAssertEqual(engine.fetchCount, 0, "a stopped transport fetches nothing")
    }

    func testAManualFetchsEventsAreNotAnEngineRun() async throws {
        let engine = FakeSyncEngine()
        let counter = EnergyCounter(defaults: defaults)
        let transport = try await phone(engine: engine, energy: counter)
        let fired = Collector<Void>()
        await transport.setEngineFetchedHandler { fired.append(()) }
        engine.onNextFetch {
            await transport.engineWillFetch()
            await transport.engineDidFetch()
        }

        try await transport.pull()

        XCTAssertEqual(counter.counts(daysAgo: 0)[.engineFetchRun], 0)
        XCTAssertEqual(fired.values.count, 0, "the pull's own fetch is not reported as an engine run")
        let running = await transport.engineRunInFlight
        XCTAssertFalse(running)
    }

    /// The event path's re-fetch after an expired token is a manual fetch:
    /// its run events are no engine run (not counted, not reported), and
    /// its zone check is counted.
    func testAnExpiredTokenRefetchIsNotAnEngineRun() async throws {
        let engine = FakeSyncEngine()
        let counter = EnergyCounter(defaults: defaults)
        let transport = try await phone(engine: engine, energy: counter)
        let fired = Collector<Void>()
        await transport.setEngineFetchedHandler { fired.append(()) }
        engine.onNextFetch {
            await transport.engineWillFetch()
            await transport.engineDidFetch()
        }

        await transport.handleFetchEventError(
            CKError(.changeTokenExpired), zoneID: HubZones.test(shared).zoneID(for: .relay)
        )

        XCTAssertEqual(engine.fetchCount, 1, "the re-fetch ran")
        let today = counter.counts(daysAgo: 0)
        XCTAssertEqual(today[.engineFetchRun], 0)
        XCTAssertEqual(today[.engineFetch], 1)
        XCTAssertEqual(today[.zoneCheck], 1)
        XCTAssertEqual(fired.values.count, 0, "the re-fetch is not reported as an engine run")
        let running = await transport.engineRunInFlight
        XCTAssertFalse(running)
    }

    func testTheEnginesOwnRunIsCountedAndReported() async throws {
        let engine = FakeSyncEngine()
        let counter = EnergyCounter(defaults: defaults)
        let transport = try await phone(engine: engine, energy: counter)
        let fired = Collector<Void>()
        await transport.setEngineFetchedHandler { fired.append(()) }

        await transport.engineWillFetch()
        XCTAssertEqual(fired.values.count, 0, "reported when the run ends")
        await transport.engineDidFetch()

        XCTAssertEqual(counter.counts(daysAgo: 0)[.engineFetchRun], 1)
        XCTAssertEqual(fired.values.count, 1)
        XCTAssertEqual(engine.fetchCount, 0)
    }
}

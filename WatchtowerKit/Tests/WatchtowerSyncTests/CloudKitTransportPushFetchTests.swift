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

    /// Waits (bounded, by yielding) until `count` push fetches wait on the
    /// engine's run.
    private func waitForWaiters(_ transport: CloudKitTransport, count: Int = 1) async throws {
        for _ in 0..<10_000 where await transport.engineRunWaiterCount < count {
            await Task.yield()
        }
        let waiting = await transport.engineRunWaiterCount
        XCTAssertEqual(waiting, count, "the push fetch never waited on the engine's run")
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
        let transport = try await phone(engine: engine, clock: clock)
        let pushedAt = clock.now
        await transport.engineWillFetch()

        let push = Task { try await transport.fetchForPush(since: pushedAt, grace: 2) }
        try await waitForWaiters(transport)
        XCTAssertEqual(engine.fetchCount, 0)
        await transport.engineDidFetch()
        try await push.value

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
        await gate.open()
        try await first.value
        try await second.value

        XCTAssertEqual(engine.fetchCount, 1, "two pushes, one fetch")
    }

    func testAPullStillPollsAfterARunningPushFetch() async throws {
        let engine = FakeSyncEngine()
        let clock = TestClock()
        let gate = Gate()
        let transport = try await phone(engine: engine, clock: clock) { _ in await gate.wait() }

        let push = Task { try await transport.fetchForPush(since: clock.now, grace: 2) }
        try await waitForWaiters(transport)
        let pull = Task { try await transport.pull() }
        await gate.open()
        try await push.value
        try await pull.value

        XCTAssertEqual(engine.fetchCount, 2, "the push's light fetch, then the pull's own")
        XCTAssertEqual(engine.zoneFetches.count, CloudZoneID.allCases.count, "only the pull polls")
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

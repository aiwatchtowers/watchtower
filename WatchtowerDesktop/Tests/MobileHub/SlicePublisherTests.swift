import Foundation
import GRDB
import os
import XCTest
@testable import WatchtowerDesktop
import WatchtowerSync
import WatchtowerTestSupport

/// The DataZone side of the hub: the hash diff over `SliceSource`s, the
/// 900 KB payload guard and the fast lane (mobile POC spec §3, §9).
final class SlicePublisherTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var state: HubSyncState!
    private var transport: StubHubTransport!

    override func setUpWithError() throws {
        (dbPool, dbPath) = try TestDatabase.createPool()
        state = try HubSyncState.inMemory()
        transport = StubHubTransport()
    }

    override func tearDownWithError() throws {
        transport = nil
        state = nil
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    private func makePublisher(
        _ sources: [any SliceSource],
        timing: SlicePublisher.Timing = .standard
    ) -> SlicePublisher {
        SlicePublisher(dbPool: dbPool, state: state, transport: transport, sources: sources, timing: timing)
    }

    private func dataSaves() -> [StubHubTransport.Saved] {
        transport.saved.filter { $0.record.zone == .data }
    }

    // MARK: - Pinned values

    /// Board #724, owner decision Q3: only asks (and the link grant the
    /// phone waits for) are sent at once; everything else rides the 30 s
    /// full tick.
    func testPinnedTimingAndGuard() {
        XCTAssertEqual(SlicePublisher.maxPayloadBytes, 900_000)
        XCTAssertEqual(SlicePublisher.Timing.standard.tick, .seconds(30))
        XCTAssertEqual(SlicePublisher.Timing.standard.urgentTick, .seconds(10))
        XCTAssertEqual(SlicePublisher.Timing.standard.fastWindow, .seconds(1))
        XCTAssertEqual(SlicePublisher.Timing.standard.fastSpacing, .seconds(2))
        XCTAssertEqual(SlicePublisher.urgentKinds, [.ownerAsk, .askAlert, .deviceGrant])
        XCTAssertEqual(SlicePublisher.unlinkedKinds, [.deviceGrant])
        XCTAssertTrue(SlicePublisher.sliceSQL.isEmpty, "A publishes no SQL slice; B and C add sources")
    }

    // MARK: - Diff

    func testSourceRecordsPublishOnceAndAnUnchangedCycleSendsNothing() async throws {
        let source = StubSliceSource(kind: .workbench)
        source.setRecords([
            SliceRecord(kind: .workbench, id: "1", modifiedAt: Date(), payload: Data(#"{"name":"acme"}"#.utf8)),
            SliceRecord(kind: .workbench, id: "2", modifiedAt: Date(), payload: Data(#"{"name":"beta"}"#.utf8))
        ])
        let publisher = makePublisher([source])

        let first = try await publisher.publishOnce()
        let second = try await publisher.publishOnce()

        XCTAssertEqual(first.pushed, 2)
        XCTAssertEqual(second.pushed, 0, "an unchanged record is not re-sent")
        XCTAssertEqual(Set(dataSaves().map(\.record.recordName)), ["workbench-1", "workbench-2"])
        XCTAssertEqual(try state.hashes(forKind: .workbench).count, 2)
    }

    func testRecordLeavingTheSourceIsDeletedAndItsHashDropped() async throws {
        let source = StubSliceSource(kind: .workbench)
        source.setPayload(Data("{}".utf8), id: "1")
        let publisher = makePublisher([source])
        try await publisher.publishOnce()

        source.setRecords([])
        let result = try await publisher.publishOnce()

        XCTAssertEqual(result.deleted, 1)
        XCTAssertTrue(try state.hashes(forKind: .workbench).isEmpty)
        let batch = try await transport.changes(in: .data, since: nil)
        XCTAssertEqual(batch.deletedRecordNames, ["workbench-1"])
    }

    func testRejectedRecordClearsOnlyItsHash() async throws {
        let source = StubSliceSource(kind: .workbench)
        source.setRecords([
            SliceRecord(kind: .workbench, id: "1", modifiedAt: Date(), payload: Data("{}".utf8)),
            SliceRecord(kind: .workbench, id: "2", modifiedAt: Date(), payload: Data("[]".utf8))
        ])
        let publisher = makePublisher([source])
        try await publisher.publishOnce()

        publisher.recordRejected("workbench-1")

        XCTAssertEqual(Set(try state.hashes(forKind: .workbench).keys), ["workbench-2"])
        let republished = try await publisher.publishOnce()
        XCTAssertEqual(republished.pushed, 1, "the rejected record is offered again")
    }

    // MARK: - Payload guard

    func testPayloadGuardBoundaries() async throws {
        let empty = StubSliceSource(kind: .workbench)
        empty.setPayload(Data(), id: "empty")
        let exact = StubSliceSource(kind: .workbenchTarget)
        exact.setPayload(Data(repeating: 0x61, count: 900_000), id: "exact")
        let over = StubSliceSource(kind: .workbenchComment)
        over.setPayload(Data(repeating: 0x61, count: 900_001), id: "over")
        let publisher = makePublisher([empty, exact, over])

        let result = try await publisher.publishOnce()

        XCTAssertEqual(result.pushed, 2)
        XCTAssertEqual(result.skipped, ["workbench_comment-over"])
        XCTAssertEqual(
            Set(dataSaves().map(\.record.recordName)), ["workbench-empty", "workbench_target-exact"],
            "an empty payload and one of exactly 900_000 bytes publish"
        )
        XCTAssertTrue(try state.hashes(forKind: .workbenchComment).isEmpty, "an oversized record is not hashed")
    }

    func testOversizedWarningIsThrottledPerRecordAndPayloadHash() async throws {
        let over = StubSliceSource(kind: .workbenchComment)
        over.setPayload(Data(repeating: 0x61, count: 900_001), id: "over")
        let publisher = makePublisher([over])

        try await publisher.publishOnce()
        try await publisher.publishOnce()
        XCTAssertEqual(publisher.oversizedWarnings, 1, "the same stuck payload warns once")

        over.setPayload(Data(repeating: 0x62, count: 900_001), id: "over")
        try await publisher.publishOnce()
        XCTAssertEqual(publisher.oversizedWarnings, 2, "a changed oversized payload warns again")

        over.setPayload(Data("{}".utf8), id: "over")
        let shrunk = try await publisher.publishOnce()
        XCTAssertEqual(shrunk.pushed, 1, "the record publishes once it fits")
    }

    // MARK: - Account reset

    func testAccountResetBetweenCyclesRepushesTheSlice() async throws {
        let source = StubSliceSource(kind: .workbench)
        source.setPayload(Data("{}".utf8))
        let publisher = makePublisher([source])
        try await publisher.publishOnce()

        try state.wipeSyncState(now: Date())
        let after = try await publisher.publishOnce()

        XCTAssertEqual(after.pushed, 1, "an account reset re-pushes the whole slice")
    }

    func testSetHashesWritesNothingOnAGenerationMismatch() throws {
        let hashes = ["workbench-1": "a", "workbench-2": "b"]
        try state.wipeSyncState(now: Date())

        XCTAssertFalse(try state.setHashes(hashes, ifGeneration: 0), "a reset landed since generation 0")
        XCTAssertEqual(try state.hashes(forKind: .workbench), [:])
        XCTAssertTrue(try state.setHashes(hashes, ifGeneration: 1))
        XCTAssertEqual(try state.hashes(forKind: .workbench), hashes)
    }

    func testRemoveHashesRemovesNothingOnAGenerationMismatch() throws {
        try state.setHash("a", for: "workbench-1")
        try state.setHash("b", for: "workbench-2")

        XCTAssertFalse(try state.removeHashes(["workbench-1"], ifGeneration: 1))
        XCTAssertEqual(try state.hashes(forKind: .workbench), ["workbench-1": "a", "workbench-2": "b"])
        XCTAssertTrue(try state.removeHashes(["workbench-1", "workbench-2"], ifGeneration: 0))
        XCTAssertEqual(try state.hashes(forKind: .workbench), [:])
    }

    // MARK: - Fast lane

    /// The fast lane's decisions on a fabricated clock: no wall-clock timing.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = ContinuousClock.now
        let origin: ContinuousClock.Instant

        init() { origin = current }

        var now: ContinuousClock.Instant { lock.withLock { current } }

        func set(_ offset: Duration) {
            lock.withLock { current = origin + offset }
        }
    }

    private func makeLanePublisher(
        _ clock: FakeClock,
        sources: [any SliceSource] = [],
        isLinked: @escaping @Sendable () -> Bool = { true },
        sendNow: @escaping @Sendable () async -> Void = {}
    ) -> SlicePublisher {
        SlicePublisher(
            dbPool: dbPool, state: state, transport: transport, sources: sources, timing: .standard,
            clock: { clock.now }, isLinked: isLinked, sendNow: sendNow
        )
    }

    /// A lane whose first cycle (the full tick, due at once) was taken at
    /// the clock's origin.
    private func startedLane(_ clock: FakeClock) -> SlicePublisher {
        let publisher = makeLanePublisher(clock)
        XCTAssertEqual(publisher.takeDueCycle(now: clock.origin), .full, "the first cycle is the full tick")
        return publisher
    }

    func testNudgesInsideTheWindowCoalesceIntoOneSend() {
        let clock = FakeClock()
        let publisher = startedLane(clock)

        publisher.nudge(kinds: [.ownerAsk])
        clock.set(.milliseconds(300))
        publisher.nudge(kinds: [.askAlert, .workbench])

        XCTAssertEqual(publisher.fastDeadline, clock.origin + .seconds(1), "the window runs from the first nudge")
        XCTAssertNil(publisher.takeDueCycle(now: clock.origin + .milliseconds(999)), "nothing is sent inside the window")
        XCTAssertEqual(
            publisher.takeDueCycle(now: clock.origin + .seconds(1)), .urgent([.ownerAsk, .askAlert]),
            "both nudges go out in one send; the normal kind is left to the tick"
        )
        XCTAssertNil(publisher.takeDueCycle(now: clock.origin + .seconds(5)), "and only one")
        XCTAssertNil(publisher.fastDeadline)
    }

    func testTwoNudgesOneAndAHalfSecondsApartAreSentAtLeastTwoSecondsApart() {
        let clock = FakeClock()
        let publisher = startedLane(clock)

        publisher.nudge(kinds: [.ownerAsk])
        let firstSend = clock.origin + .seconds(1)
        XCTAssertEqual(publisher.takeDueCycle(now: firstSend), .urgent([.ownerAsk]))

        clock.set(.milliseconds(1_500))
        publisher.nudge(kinds: [.ownerAsk])

        XCTAssertEqual(publisher.fastDeadline, firstSend + .seconds(2), "the spacing outlasts the second window")
        XCTAssertNil(
            publisher.takeDueCycle(now: clock.origin + .milliseconds(2_500)),
            "the second window has ended, but the 2 s spacing has not"
        )
        XCTAssertNil(publisher.takeDueCycle(now: firstSend + .milliseconds(1_999)))
        XCTAssertEqual(publisher.takeDueCycle(now: firstSend + .seconds(2)), .urgent([.ownerAsk]), "sent 2 s after the first")
    }

    func testANudgeAfterAQuietSpellWaitsOnlyForItsWindow() {
        let clock = FakeClock()
        let publisher = startedLane(clock)
        publisher.nudge(kinds: [.ownerAsk])
        XCTAssertNotNil(publisher.takeDueCycle(now: clock.origin + .seconds(1)))

        clock.set(.seconds(5))
        publisher.nudge(kinds: [.ownerAsk])

        XCTAssertEqual(publisher.fastDeadline, clock.origin + .seconds(6), "the spacing has long passed")
    }

    /// A normal kind's nudge opens no fast send: the urgent tick diffs the
    /// urgent kinds alone, and the kind waits for the 30 s full tick.
    func testANormalNudgeWaitsForTheFullTick() {
        let clock = FakeClock()
        let publisher = startedLane(clock)

        publisher.nudge(kinds: [.workbench, .terminalSession, .workbenchTarget])

        XCTAssertNil(publisher.fastDeadline, "no fast send for normal kinds")
        XCTAssertNil(publisher.takeDueCycle(now: clock.origin + .milliseconds(9_999)))
        XCTAssertEqual(
            publisher.takeDueCycle(now: clock.origin + .seconds(10)), .urgent(SlicePublisher.urgentKinds),
            "the urgent tick diffs only the urgent kinds"
        )
        XCTAssertNotEqual(publisher.takeDueCycle(now: clock.origin + .milliseconds(29_999)), .full)
        XCTAssertEqual(publisher.takeDueCycle(now: clock.origin + .seconds(30)), .full)
    }

    /// Owner decision Q3: a normal kind changing every 250 ms for two
    /// minutes, nudging each time, is saved at most once per 30 s and never
    /// asks for an immediate send.
    func testANormalKindIsSavedAtMostOncePerThirtySeconds() async throws {
        let clock = FakeClock()
        let source = StubSliceSource(kind: .workbench)
        let sends = SendCounter()
        let publisher = makeLanePublisher(clock, sources: [source]) { await sends.bump() }
        var saveTimes: [Duration] = []
        for step in 0...480 {
            let offset = Duration.milliseconds(250 * step)
            clock.set(offset)
            source.setPayload(Data(#"{"step":\#(step)}"#.utf8))
            publisher.nudge(kinds: [.workbench])
            let before = dataSaves().count
            if let cycle = publisher.takeDueCycle(now: clock.now) {
                await publisher.run(cycle)
            }
            if dataSaves().count > before { saveTimes.append(offset) }
        }

        XCTAssertEqual(saveTimes, [.zero, .seconds(30), .seconds(60), .seconds(90), .seconds(120)])
        XCTAssertEqual(sends.count, 0, "a normal kind never asks for an immediate send")
    }

    /// Any cycle that saved an urgent record sends at once: the fast lane,
    /// the urgent tick (an ask Go wrote, which no nudge sees) and the full
    /// tick. A cycle that saved only normal records leaves the send to
    /// CKSyncEngine.
    func testEveryCycleThatChangedAnUrgentRecordSendsNow() async throws {
        let clock = FakeClock()
        let ask = StubSliceSource(kind: .ownerAsk)
        let bench = StubSliceSource(kind: .workbench)
        ask.setPayload(Data(#"{"v":1}"#.utf8))
        bench.setPayload(Data(#"{"v":1}"#.utf8))
        let sends = SendCounter()
        let publisher = makeLanePublisher(clock, sources: [ask, bench]) { await sends.bump() }

        await publisher.run(try XCTUnwrap(publisher.takeDueCycle(now: clock.origin)))
        XCTAssertEqual(sends.count, 1, "the first full tick published an ask")

        ask.setPayload(Data(#"{"v":2}"#.utf8))
        clock.set(.seconds(3))
        publisher.nudge(kinds: [.ownerAsk])
        await publisher.run(try XCTUnwrap(publisher.takeDueCycle(now: clock.origin + .seconds(4))))
        XCTAssertEqual(sends.count, 2, "the fast lane")

        ask.setPayload(Data(#"{"v":3}"#.utf8))
        let urgentTick = try XCTUnwrap(publisher.takeDueCycle(now: clock.origin + .seconds(10)))
        XCTAssertEqual(urgentTick, .urgent(SlicePublisher.urgentKinds))
        await publisher.run(urgentTick)
        XCTAssertEqual(sends.count, 3, "the urgent tick")

        bench.setPayload(Data(#"{"v":2}"#.utf8))
        let full = try XCTUnwrap(publisher.takeDueCycle(now: clock.origin + .seconds(30)))
        XCTAssertEqual(full, .full)
        let result = await publisher.run(full)
        let outcome = try XCTUnwrap(result)
        XCTAssertEqual(outcome.pushed, 1)
        XCTAssertEqual(sends.count, 3, "a normal change alone sends nothing at once")
    }

    /// Board #724: without a linked phone nothing but the link flow's
    /// answer is published; the first cycle that sees a phone publishes
    /// every kind, and then the cycles keep their own scope.
    func testWithoutALinkedPhoneOnlyTheDeviceGrantIsPublished() async throws {
        let clock = FakeClock()
        let linked = OSAllocatedUnfairLock(initialState: false)
        let grant = StubSliceSource(kind: .deviceGrant)
        let bench = StubSliceSource(kind: .workbench)
        let ask = StubSliceSource(kind: .ownerAsk)
        grant.setPayload(Data(#"{"linked":false}"#.utf8), id: "phone")
        bench.setPayload(Data(#"{"v":1}"#.utf8))
        ask.setPayload(Data(#"{"v":1}"#.utf8))
        let isLinked: @Sendable () -> Bool = { linked.withLock { $0 } }
        let publisher = makeLanePublisher(clock, sources: [grant, bench, ask], isLinked: isLinked)

        await publisher.run(.full)
        await publisher.run(.urgent(SlicePublisher.urgentKinds))
        XCTAssertEqual(dataSaves().map(\.record.recordName), ["device_grant-phone"])
        XCTAssertEqual(bench.reads, 0, "an unlinked hub does not even read the other kinds")
        XCTAssertEqual(ask.reads, 0)

        linked.withLock { $0 = true }
        grant.setPayload(Data(#"{"linked":true}"#.utf8), id: "phone")
        await publisher.run(.urgent([.deviceGrant]))
        XCTAssertEqual(
            Set(dataSaves().map(\.record.recordName)), ["device_grant-phone", "workbench-1", "owner_ask-1"],
            "the cycle that sees the new phone publishes everything"
        )

        bench.setPayload(Data(#"{"v":2}"#.utf8))
        await publisher.run(.urgent([.deviceGrant]))
        XCTAssertEqual(dataSaves().count, 4, "later urgent cycles keep their own scope")
    }

    /// Board #724: a new phone's grant is saved and sent ahead of the
    /// backlog of every other kind (the transport sends oldest first, and
    /// the phone's link flow waits 60 s for the grant).
    func testANewPhonesGrantIsSavedAndSentBeforeTheBacklog() async throws {
        let clock = FakeClock()
        let linked = OSAllocatedUnfairLock(initialState: false)
        let grant = StubSliceSource(kind: .deviceGrant)
        let bench = StubSliceSource(kind: .workbench)
        let target = StubSliceSource(kind: .workbenchTarget)
        let transcript = StubSliceSource(kind: .meetingTranscript)
        grant.setPayload(Data(#"{"linked":false}"#.utf8), id: "phone")
        for source in [bench, target, transcript] {
            source.setRecords((1...3).map { SliceRecord(kind: source.kind, id: "\($0)", modifiedAt: Date(), payload: Data("{}".utf8)) })
        }
        let transport = try XCTUnwrap(self.transport)
        let sentWith = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        let isLinked: @Sendable () -> Bool = { linked.withLock { $0 } }
        let publisher = makeLanePublisher(clock, sources: [bench, target, transcript, grant], isLinked: isLinked) {
            let names = transport.saved.filter { $0.record.zone == .data }.map(\.record.recordName)
            sentWith.withLock { $0.append(names) }
        }
        await publisher.run(.full)
        sentWith.withLock { $0 = [] }

        linked.withLock { $0 = true }
        grant.setPayload(Data(#"{"linked":true}"#.utf8), id: "phone")
        let result = await publisher.run(.urgent([.deviceGrant]))

        let names = dataSaves().map(\.record.recordName)
        XCTAssertEqual(Array(names.prefix(2)), ["device_grant-phone", "device_grant-phone"], "the grant is saved first")
        XCTAssertEqual(names.count, 11, "then the backlog of every other kind")
        XCTAssertEqual(
            sentWith.withLock { $0 }, [["device_grant-phone", "device_grant-phone"]],
            "the grant is sent alone, before the backlog is saved"
        )
        let outcome = try XCTUnwrap(result)
        XCTAssertEqual(outcome.pushed, 10, "the outcome covers both passes")
        XCTAssertEqual(outcome.urgentChanges, 1)
    }

    /// Every cycle diffs the urgent kinds first, so a save batch carries
    /// an ask ahead of the normal records.
    func testACycleSavesTheUrgentKindsFirst() async throws {
        let bench = StubSliceSource(kind: .workbench)
        let ask = StubSliceSource(kind: .ownerAsk)
        bench.setPayload(Data(#"{"v":1}"#.utf8))
        ask.setPayload(Data(#"{"v":1}"#.utf8))
        let publisher = makePublisher([bench, ask])

        try await publisher.publishOnce()

        XCTAssertEqual(dataSaves().map(\.record.recordName), ["owner_ask-1", "workbench-1"])
    }

    /// The first linked cycle's full pass failed: the next cycle publishes
    /// every kind again, whatever its own scope.
    func testAFailedFirstLinkedCycleIsRetriedInFull() async throws {
        let clock = FakeClock()
        let linked = OSAllocatedUnfairLock(initialState: false)
        let grant = StubSliceSource(kind: .deviceGrant)
        let bench = StubSliceSource(kind: .workbench)
        grant.setPayload(Data(#"{"linked":false}"#.utf8), id: "phone")
        bench.setPayload(Data(#"{"v":1}"#.utf8))
        let isLinked: @Sendable () -> Bool = { linked.withLock { $0 } }
        let publisher = makeLanePublisher(clock, sources: [grant, bench], isLinked: isLinked)
        await publisher.run(.full)

        linked.withLock { $0 = true }
        grant.setPayload(Data(#"{"linked":true}"#.utf8), id: "phone")
        transport.failNextSaves(2)
        let failed = await publisher.run(.urgent([.deviceGrant]))
        XCTAssertNil(failed, "both passes failed")
        XCTAssertEqual(bench.reads, 0, "the full pass stopped at the grant")

        await publisher.run(.urgent([.deviceGrant]))
        XCTAssertEqual(
            dataSaves().map(\.record.recordName), ["device_grant-phone", "device_grant-phone", "workbench-1"],
            "the retry still publishes every kind"
        )

        bench.setPayload(Data(#"{"v":2}"#.utf8))
        await publisher.run(.urgent([.deviceGrant]))
        XCTAssertEqual(dataSaves().count, 3, "once it ran to its end, cycles keep their own scope")
    }

    func testStartWithoutStopCancelsTheOldSleepAndKeepsTheNewHandle() async throws {
        let source = StubSliceSource(kind: .workbench)
        let publisher = makePublisher(
            [source], timing: .init(tick: .seconds(3_600), fastWindow: .seconds(1), fastSpacing: .seconds(2))
        )
        publisher.start()
        defer { publisher.stop() }
        await awaitHubCondition("the first loop sleeps") { publisher.currentSleepForTesting != nil }
        let oldSleep = try XCTUnwrap(publisher.currentSleepForTesting)
        let oldLoop = try XCTUnwrap(publisher.loopTaskForTesting)

        publisher.start()

        XCTAssertTrue(oldSleep.isCancelled, "a restart cancels the old loop's sleep at once")
        // Should that guard break, end the old sleep here so the test fails
        // on the assertion above instead of waiting out the hour-long tick.
        oldSleep.cancel()
        await awaitHubCondition("the new loop sleeps") {
            publisher.currentSleepForTesting.map { $0 != oldSleep } ?? false
        }
        let newSleep = try XCTUnwrap(publisher.currentSleepForTesting)
        await oldLoop.value
        XCTAssertEqual(publisher.currentSleepForTesting, newSleep, "the old loop's exit leaves the new handle alone")

        publisher.nudge(kinds: [.ownerAsk])
        XCTAssertTrue(newSleep.isCancelled, "a nudge still wakes the new loop")
    }

    func testAnEndingSleepNeverClearsANewerLoopsHandle() {
        let publisher = makeLanePublisher(FakeClock())
        let far = ContinuousClock.now + .seconds(3_600)
        let oldSleep = publisher.beginSleep(tick: far)
        let newSleep = publisher.beginSleep(tick: far)
        defer {
            oldSleep.cancel()
            newSleep.cancel()
        }

        publisher.endSleep(oldSleep)
        XCTAssertEqual(publisher.currentSleepForTesting, newSleep, "the old loop's exit leaves the new handle alone")

        publisher.nudge(kinds: [.ownerAsk])
        XCTAssertTrue(newSleep.isCancelled, "so a nudge still wakes the new loop")

        publisher.endSleep(newSleep)
        XCTAssertNil(publisher.currentSleepForTesting, "a loop forgets its own handle")
    }

    func testANudgeReadsOnlyTheNudgedKinds() async throws {
        let nudged = StubSliceSource(kind: .ownerAsk)
        let other = StubSliceSource(kind: .workbench)
        let publisher = makePublisher(
            [nudged, other], timing: .init(tick: .seconds(60), fastWindow: .milliseconds(50), fastSpacing: .milliseconds(100))
        )
        publisher.start()
        defer { publisher.stop() }
        await awaitHubCondition("the start cycle reads every source") { nudged.reads == 1 && other.reads == 1 }

        publisher.nudge(kinds: [.ownerAsk])

        await awaitHubCondition("the fast lane reads the nudged source") { nudged.reads == 2 }
        XCTAssertEqual(other.reads, 1, "a fast send diffs only the nudged kinds")
    }

    /// Spec §4.5 through the running loop: a fast cycle that saved an ask
    /// asks the transport to send at once; an unchanged fast cycle does
    /// not, and a normal kind's nudge runs no fast cycle at all.
    func testOnlyALoopCycleThatSavedAnAskAsksForAnImmediateSend() async throws {
        let ask = StubSliceSource(kind: .ownerAsk)
        let bench = StubSliceSource(kind: .workbench)
        ask.setPayload(Data(#"{"v":1}"#.utf8))
        let transport = try XCTUnwrap(self.transport)
        let publisher = SlicePublisher(
            dbPool: dbPool, state: state, transport: transport, sources: [ask, bench],
            timing: .init(tick: .seconds(60), fastWindow: .milliseconds(50), fastSpacing: .milliseconds(100)),
            sendNow: { await transport.sendNow() } // swiftlint:disable:this trailing_closure
        )
        publisher.start()
        defer { publisher.stop() }
        await awaitHubCondition("the start cycle (the tick) publishes the ask") { transport.sendNowCalls == 1 }

        publisher.nudge(kinds: [.ownerAsk])
        await awaitHubCondition("an unchanged fast cycle finished") { publisher.fastCyclesCompleted == 1 }
        XCTAssertEqual(ask.reads, 2)
        XCTAssertEqual(transport.sendNowCalls, 1, "an empty fast diff sends nothing")

        bench.setPayload(Data(#"{"v":1}"#.utf8))
        publisher.nudge(kinds: [.workbench])
        ask.setPayload(Data(#"{"v":2}"#.utf8))
        publisher.nudge(kinds: [.ownerAsk])
        await awaitHubCondition("the changed ask is sent at once") { transport.sendNowCalls == 2 }
        XCTAssertEqual(bench.reads, 1, "the workbench nudge waits for the full tick")
        XCTAssertEqual(dataSaves().map(\.record.recordName), ["owner_ask-1", "owner_ask-1"])
    }

    func testStopEndsTheLoop() async throws {
        let source = StubSliceSource(kind: .workbench)
        let publisher = makePublisher([source], timing: .init(tick: .milliseconds(20), fastWindow: .milliseconds(10), fastSpacing: .milliseconds(10)))
        publisher.start()
        XCTAssertTrue(publisher.isRunning)
        await awaitHubCondition("the loop ticks") { source.reads >= 2 }

        publisher.stop()
        XCTAssertFalse(publisher.isRunning)
        try await Task.sleep(for: .milliseconds(100))
        let settled = source.reads
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(source.reads, settled, "no cycle runs after stop()")
    }

    // MARK: - Asset-backed records

    private func withAssetStore(_ body: (SliceAssetStore) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("slice-assets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(SliceAssetStore(directory: dir))
    }

    private func assetPublisher(_ source: StubAssetSliceSource, store: SliceAssetStore?) -> SlicePublisher {
        SlicePublisher(dbPool: dbPool, state: state, transport: transport, sources: [source], assets: store)
    }

    func testAnAssetRecordIsStagedAndSavedWithItsFile() async throws {
        try await withAssetStore { store in
            let source = StubAssetSliceSource()
            source.set(id: "7", payload: #"{"id":7}"#, asset: "[1]")
            let result = try await assetPublisher(source, store: store).publishOnce()

            XCTAssertEqual(result.pushed, 1)
            let saved = try XCTUnwrap(dataSaves().last?.record)
            let file = try XCTUnwrap(saved.assetFileURL, "the asset rides as the record's CKAsset")
            XCTAssertEqual(file, store.fileURL(recordName: "meeting_transcript-7", fileName: "segments.json"))
            XCTAssertEqual(try Data(contentsOf: file), Data("[1]".utf8))
            XCTAssertEqual(saved.payload, Data(#"{"id":7}"#.utf8), "the asset is not in the payload")
        }
    }

    func testAChangedAssetAloneRepublishesAndReplacesTheFile() async throws {
        try await withAssetStore { store in
            let source = StubAssetSliceSource()
            source.set(id: "7", payload: "{}", asset: "[1]")
            let publisher = assetPublisher(source, store: store)
            try await publisher.publishOnce()
            let unchanged = try await publisher.publishOnce()
            XCTAssertEqual(unchanged.pushed, 0, "same payload and asset: nothing sent")

            source.set(id: "7", payload: "{}", asset: "[2]")
            let changed = try await publisher.publishOnce()

            XCTAssertEqual(changed.pushed, 1, "the hash covers the asset's content")
            let file = store.fileURL(recordName: "meeting_transcript-7", fileName: "segments.json")
            XCTAssertEqual(try Data(contentsOf: file), Data("[2]".utf8))
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["segments.json"],
                "replaced in place, no second file"
            )
        }
    }

    func testARecordLeavingTheWindowRemovesItsStagedFile() async throws {
        try await withAssetStore { store in
            let source = StubAssetSliceSource()
            source.set(id: "7", payload: "{}", asset: "[1]")
            source.add(id: "8", payload: "{}", asset: "[2]")
            let publisher = assetPublisher(source, store: store)
            try await publisher.publishOnce()

            source.set(id: "8", payload: "{}", asset: "[2]")
            let result = try await publisher.publishOnce()

            XCTAssertEqual(result.deleted, 1)
            XCTAssertFalse(store.isStaged(recordName: "meeting_transcript-7", fileName: "segments.json"))
            XCTAssertTrue(store.isStaged(recordName: "meeting_transcript-8", fileName: "segments.json"))
        }
    }

    func testAMissingStagedFileIsPublishedAgain() async throws {
        try await withAssetStore { store in
            let source = StubAssetSliceSource()
            source.set(id: "7", payload: "{}", asset: "[1]")
            let publisher = assetPublisher(source, store: store)
            try await publisher.publishOnce()

            publisher.removeStagedAssets()
            let result = try await publisher.publishOnce()

            XCTAssertEqual(result.pushed, 1, "a matching hash without its file is not believed published")
            XCTAssertTrue(store.isStaged(recordName: "meeting_transcript-7", fileName: "segments.json"))
        }
    }

    func testAClosedStoreStagesNothingUntilStart() async throws {
        try await withAssetStore { store in
            let source = StubAssetSliceSource()
            source.set(id: "7", payload: "{}", asset: "[1]")
            let publisher = assetPublisher(source, store: store)
            try await publisher.publishOnce()

            publisher.closeStagedAssets()
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path), "turning the hub off removes the files")
            let closed = try await publisher.publishOnce()
            XCTAssertEqual(closed.pushed, 0)
            XCTAssertEqual(closed.skipped, ["meeting_transcript-7"], "skipped unhashed, retried later")
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path), "a cycle after the close leaves no file")

            publisher.start()
            await awaitHubCondition("start reopens the store and the cycle restages the file") {
                self.dataSaves().count == 2 && store.isStaged(recordName: "meeting_transcript-7", fileName: "segments.json")
            }
            publisher.stop()
        }
    }

    func testAnAssetRecordWithoutAStoreIsSkipped() async throws {
        let source = StubAssetSliceSource()
        source.set(id: "7", payload: "{}", asset: "[1]")
        let result = try await assetPublisher(source, store: nil).publishOnce()

        XCTAssertEqual(result.pushed, 0)
        XCTAssertEqual(result.skipped, ["meeting_transcript-7"])
        XCTAssertTrue(try state.hashes(forKind: .meetingTranscript).isEmpty)
    }

    func testTheAssetHashIsThePayloadPlusTheAssetContent() {
        let record = SliceRecord(kind: .meetingTranscript, id: "7", modifiedAt: Date(), payload: Data("{}".utf8))
        XCTAssertEqual(SliceDiff.recordHash(record, asset: nil), SliceDiff.hashHex(record.payload), "no asset: the payload hash")
        let one = SliceDiff.recordHash(record, asset: SliceAsset(fileName: "segments.json", data: Data("[1]".utf8)))
        let two = SliceDiff.recordHash(record, asset: SliceAsset(fileName: "segments.json", data: Data("[2]".utf8)))
        XCTAssertNotEqual(one, two)
        XCTAssertNotEqual(one, SliceDiff.hashHex(record.payload))
    }
}

/// An `AssetSliceSource` over `meeting_transcript` with settable records.
private final class StubAssetSliceSource: AssetSliceSource, @unchecked Sendable {
    let kind = SliceKind.meetingTranscript
    private let lock = NSLock()
    private var current: [AssetSliceRecord] = []

    func set(id: String, payload: String, asset: String) {
        lock.withLock { current = [Self.record(id: id, payload: payload, asset: asset)] }
    }

    func add(id: String, payload: String, asset: String) {
        lock.withLock { current.append(Self.record(id: id, payload: payload, asset: asset)) }
    }

    func assetRecords(
        _ db: Database,
        stagedDigest: @escaping (_ recordName: String, _ fileName: String) -> Data?
    ) throws -> () throws -> [AssetSliceRecord] {
        let records = lock.withLock { current }
        return { records }
    }

    private static func record(id: String, payload: String, asset: String) -> AssetSliceRecord {
        AssetSliceRecord(
            record: SliceRecord(kind: .meetingTranscript, id: id, modifiedAt: Date(), payload: Data(payload.utf8)),
            asset: SliceAsset(fileName: "segments.json", data: Data(asset.utf8))
        )
    }
}

/// Counts the publisher's immediate sends.
private final class SendCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func bump() { lock.withLock { calls += 1 } }
}

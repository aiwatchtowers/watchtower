import Foundation
import GRDB
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

    func testPinnedTimingAndGuard() {
        XCTAssertEqual(SlicePublisher.maxPayloadBytes, 900_000)
        XCTAssertEqual(SlicePublisher.Timing.standard.tick, .seconds(10))
        XCTAssertEqual(SlicePublisher.Timing.standard.fastWindow, .seconds(1))
        XCTAssertEqual(SlicePublisher.Timing.standard.fastSpacing, .seconds(2))
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

        try state.wipeSyncState()
        let after = try await publisher.publishOnce()

        XCTAssertEqual(after.pushed, 1, "an account reset re-pushes the whole slice")
    }

    // MARK: - Fast lane

    func testNudgesInsideTheWindowCoalesceIntoOneSend() async throws {
        let source = StubSliceSource(kind: .workbench)
        source.setPayload(Data(#"{"v":0}"#.utf8))
        let publisher = makePublisher([source], timing: .init(tick: .seconds(60), fastWindow: .seconds(1), fastSpacing: .seconds(2)))
        publisher.start()
        defer { publisher.stop() }
        await awaitHubCondition("the start cycle publishes") { dataSaves().count == 1 }

        source.setPayload(Data(#"{"v":1}"#.utf8))
        publisher.nudge(kinds: [.workbench])
        try await Task.sleep(for: .milliseconds(300))
        source.setPayload(Data(#"{"v":2}"#.utf8))
        publisher.nudge(kinds: [.workbench])

        await awaitHubCondition("the fast lane sends") { dataSaves().count == 2 }
        try await Task.sleep(for: .milliseconds(2_500))
        let saves = dataSaves()
        XCTAssertEqual(saves.count, 2, "two nudges inside the window are one send")
        XCTAssertEqual(saves.last?.record.payload, Data(#"{"v":2}"#.utf8), "the send carries the latest state")
    }

    func testTwoNudgesOneAndAHalfSecondsApartAreSentAtLeastTwoSecondsApart() async throws {
        let source = StubSliceSource(kind: .workbench)
        source.setPayload(Data(#"{"v":0}"#.utf8))
        let publisher = makePublisher([source], timing: .init(tick: .seconds(60), fastWindow: .seconds(1), fastSpacing: .seconds(2)))
        publisher.start()
        defer { publisher.stop() }
        await awaitHubCondition("the start cycle publishes") { dataSaves().count == 1 }

        let firstNudge = ContinuousClock.now
        source.setPayload(Data(#"{"v":1}"#.utf8))
        publisher.nudge(kinds: [.workbench])
        try await Task.sleep(until: firstNudge + .milliseconds(1_500), clock: .continuous)
        let secondNudge = ContinuousClock.now
        source.setPayload(Data(#"{"v":2}"#.utf8))
        publisher.nudge(kinds: [.workbench])

        await awaitHubCondition("both fast sends land", timeout: 8) { dataSaves().count == 3 }
        let saves = dataSaves()
        XCTAssertGreaterThanOrEqual(saves[1].at - firstNudge, .seconds(1), "a nudge waits out the 1 s window")
        XCTAssertGreaterThanOrEqual(saves[2].at - saves[1].at, .seconds(2), "fast sends are at least 2 s apart")
        XCTAssertGreaterThanOrEqual(saves[2].at - secondNudge, .seconds(1))
    }

    func testANudgeReadsOnlyTheNudgedKinds() async throws {
        let nudged = StubSliceSource(kind: .workbench)
        let other = StubSliceSource(kind: .ownerAsk)
        let publisher = makePublisher(
            [nudged, other], timing: .init(tick: .seconds(60), fastWindow: .milliseconds(50), fastSpacing: .milliseconds(100))
        )
        publisher.start()
        defer { publisher.stop() }
        await awaitHubCondition("the start cycle reads every source") { nudged.reads == 1 && other.reads == 1 }

        publisher.nudge(kinds: [.workbench])

        await awaitHubCondition("the fast lane reads the nudged source") { nudged.reads == 2 }
        XCTAssertEqual(other.reads, 1, "a fast send diffs only the nudged kinds")
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
}

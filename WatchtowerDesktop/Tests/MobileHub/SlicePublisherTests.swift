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

    private func makeLanePublisher(_ clock: FakeClock) -> SlicePublisher {
        SlicePublisher(
            dbPool: dbPool, state: state, transport: transport, sources: [], timing: .standard
        ) { clock.now }
    }

    func testNudgesInsideTheWindowCoalesceIntoOneSend() {
        let clock = FakeClock()
        let publisher = makeLanePublisher(clock)

        publisher.nudge(kinds: [.workbench])
        clock.set(.milliseconds(300))
        publisher.nudge(kinds: [.ownerAsk])

        XCTAssertEqual(publisher.fastDeadline, clock.origin + .seconds(1), "the window runs from the first nudge")
        XCTAssertNil(publisher.takeDueFastKinds(now: clock.origin + .milliseconds(999)), "nothing is sent inside the window")
        XCTAssertEqual(
            publisher.takeDueFastKinds(now: clock.origin + .seconds(1)), [.workbench, .ownerAsk],
            "both nudges go out in one send"
        )
        XCTAssertNil(publisher.takeDueFastKinds(now: clock.origin + .seconds(5)), "and only one")
        XCTAssertNil(publisher.fastDeadline)
    }

    func testTwoNudgesOneAndAHalfSecondsApartAreSentAtLeastTwoSecondsApart() {
        let clock = FakeClock()
        let publisher = makeLanePublisher(clock)

        publisher.nudge(kinds: [.workbench])
        let firstSend = clock.origin + .seconds(1)
        XCTAssertEqual(publisher.takeDueFastKinds(now: firstSend), [.workbench])

        clock.set(.milliseconds(1_500))
        publisher.nudge(kinds: [.workbench])

        XCTAssertEqual(publisher.fastDeadline, firstSend + .seconds(2), "the spacing outlasts the second window")
        XCTAssertNil(
            publisher.takeDueFastKinds(now: clock.origin + .milliseconds(2_500)),
            "the second window has ended, but the 2 s spacing has not"
        )
        XCTAssertNil(publisher.takeDueFastKinds(now: firstSend + .milliseconds(1_999)))
        XCTAssertEqual(publisher.takeDueFastKinds(now: firstSend + .seconds(2)), [.workbench], "sent 2 s after the first")
    }

    func testANudgeAfterAQuietSpellWaitsOnlyForItsWindow() {
        let clock = FakeClock()
        let publisher = makeLanePublisher(clock)
        publisher.nudge(kinds: [.workbench])
        XCTAssertNotNil(publisher.takeDueFastKinds(now: clock.origin + .seconds(1)))

        clock.set(.seconds(10))
        publisher.nudge(kinds: [.workbench])

        XCTAssertEqual(publisher.fastDeadline, clock.origin + .seconds(11), "the spacing has long passed")
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

        publisher.nudge(kinds: [.workbench])
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

        publisher.nudge(kinds: [.workbench])
        XCTAssertTrue(newSleep.isCancelled, "so a nudge still wakes the new loop")

        publisher.endSleep(newSleep)
        XCTAssertNil(publisher.currentSleepForTesting, "a loop forgets its own handle")
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

    /// Spec §4.5: a fast cycle that saved something asks the transport to
    /// send at once; a fast cycle with an empty diff and the regular tick
    /// leave the timing to CKSyncEngine.
    func testOnlyAFastCycleThatSavedAsksForAnImmediateSend() async throws {
        let source = StubSliceSource(kind: .workbench)
        source.setPayload(Data(#"{"v":1}"#.utf8))
        let transport = try XCTUnwrap(self.transport)
        let publisher = SlicePublisher(
            dbPool: dbPool, state: state, transport: transport, sources: [source],
            timing: .init(tick: .seconds(60), fastWindow: .milliseconds(50), fastSpacing: .milliseconds(100)),
            sendNow: { await transport.sendNow() } // swiftlint:disable:this trailing_closure
        )
        publisher.start()
        defer { publisher.stop() }
        await awaitHubCondition("the start cycle (the tick) publishes") { self.dataSaves().count == 1 && publisher.lastPublishAt != nil }
        XCTAssertEqual(transport.sendNowCalls, 0, "the tick leaves the send to CKSyncEngine")

        publisher.nudge(kinds: [.workbench])
        await awaitHubCondition("an unchanged fast cycle finished") { publisher.fastCyclesCompleted == 1 }
        XCTAssertEqual(source.reads, 2)
        XCTAssertEqual(transport.sendNowCalls, 0, "an empty fast diff sends nothing")

        source.setPayload(Data(#"{"v":2}"#.utf8))
        publisher.nudge(kinds: [.workbench])
        await awaitHubCondition("the changed record is sent at once") { transport.sendNowCalls == 1 }
        XCTAssertEqual(dataSaves().count, 2)
        XCTAssertEqual(transport.sendNowCalls, 1, "exactly one immediate send")
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

    func assetRecords(_ db: Database) throws -> [AssetSliceRecord] {
        lock.withLock { current }
    }

    private static func record(id: String, payload: String, asset: String) -> AssetSliceRecord {
        AssetSliceRecord(
            record: SliceRecord(kind: .meetingTranscript, id: id, modifiedAt: Date(), payload: Data(payload.utf8)),
            asset: SliceAsset(fileName: "segments.json", data: Data(asset.utf8))
        )
    }
}

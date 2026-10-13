import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerE2ETesting
import WatchtowerSync
import WatchtowerTestSupport

/// The DataZone side of the hub: the hash diff over `SliceSource`s, the
/// sealed-size guard, sealing (mobile E2E spec §2.4, §2.7) and the fast lane
/// (mobile POC spec §3, §9). Every record is read back through the paired
/// test phone (`TestOpening`).
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
        SlicePublisher(
            dbPool: dbPool, state: state, transport: transport.sealing(names: state), sources: sources, timing: timing
        )
    }

    /// The DataZone saves, opened by the paired phone.
    private func dataSaves() throws -> [StubHubTransport.Saved] {
        try transport.openedSaves().filter { $0.record.zone == .data }
    }

    /// The sealed DataZone saves as they went to the transport.
    private func wireSaves() -> [CloudRecord] {
        transport.saved.map(\.record).filter { $0.zone == .data }
    }

    private func wireName(_ plain: String) throws -> String {
        try testSecureTransport(InMemoryCloudTransport()).wireName(plain: plain, zone: .data)
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
        XCTAssertEqual(Set(try dataSaves().map(\.record.recordName)), ["workbench-1", "workbench-2"])
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
        XCTAssertEqual(batch.deletedRecordNames, [try wireName("workbench-1")], "deleted under its opaque name")
    }

    /// The transport hands the rejection over by wire name; the hash of the plain name it maps to is cleared.
    func testARejectedRecordClearsThePlainNamesHash() async throws {
        let source = StubSliceSource(kind: .workbench)
        source.setRecords([
            SliceRecord(kind: .workbench, id: "1", modifiedAt: Date(), payload: Data("{}".utf8)),
            SliceRecord(kind: .workbench, id: "2", modifiedAt: Date(), payload: Data("[]".utf8))
        ])
        let publisher = makePublisher([source])
        try await publisher.publishOnce()
        let wire = try wireName("workbench-1")
        XCTAssertEqual(state.plainName(forWire: wire), "workbench-1", "slice_state keeps the opaque name (F19)")

        await publisher.recordRejected(wireName: wire)

        XCTAssertEqual(Set(try state.hashes(forKind: .workbench).keys), ["workbench-2"])
        let republished = try await publisher.publishOnce()
        XCTAssertEqual(republished.pushed, 1, "the rejected record is offered again")
    }

    /// F19: CKSyncEngine may reject a record it queued in an earlier launch. A new transport (nothing sealed in
    /// this process) still maps the wire name through `slice_state.wire_name`.
    func testARejectionAfterARelaunchStillMapsToThePlainName() async throws {
        let source = StubSliceSource(kind: .workbench)
        source.setPayload(Data("{}".utf8), id: "1")
        try await makePublisher([source]).publishOnce()
        let wire = try wireName("workbench-1")

        let forgetful = SlicePublisher(dbPool: dbPool, state: state, transport: transport.sealing(), sources: [source])
        await forgetful.recordRejected(wireName: wire)
        XCTAssertEqual(
            Set(try state.hashes(forKind: .workbench).keys), ["workbench-1"],
            "control: without the persisted index a fresh transport cannot map the name"
        )

        let relaunched = SlicePublisher(
            dbPool: dbPool, state: state, transport: transport.sealing(names: state), sources: [source]
        )
        await relaunched.recordRejected(wireName: wire)

        XCTAssertTrue(try state.hashes(forKind: .workbench).isEmpty, "the relaunched hub cleared the plain name's hash")
        let republished = try await relaunched.publishOnce()
        XCTAssertEqual(republished.pushed, 1)
    }

    // MARK: - Sealing

    func testEveryPublishedRecordIsASignedEnvelopeUnderAnOpaqueName() async throws {
        let source = StubSliceSource(kind: .workbench)
        source.setRecords([
            SliceRecord(kind: .workbench, id: "1", modifiedAt: Date(), payload: Data(#"{"name":"acme"}"#.utf8)),
            SliceRecord(
                kind: .workbench, id: "2", modifiedAt: Date(), payload: Data(#"{"name":"beta"}"#.utf8), notifyLevel: "high"
            )
        ])

        let result = try await makePublisher([source]).publishOnce()

        XCTAssertEqual(result.pushed, 2)
        let wire = wireSaves()
        XCTAssertEqual(wire.count, 2)
        for record in wire {
            XCTAssertEqual(record.kind, WireKind.envelope, "the wire kind is the constant")
            XCTAssertNil(record.notifyLevel, "no notify level in the clear")
            XCTAssertFalse(record.recordName.hasPrefix("workbench"), "an opaque name: \(record.recordName)")
            XCTAssertNil(record.payload.range(of: Data("acme".utf8)), "no plaintext on the wire")
            XCTAssertNil(record.payload.range(of: Data("beta".utf8)), "no plaintext on the wire")
            let header = try Envelope.parse(record.payload).header
            XCTAssertTrue(header.flags.contains(.signed), "every DataZone envelope is signed by hub_sig")
            XCTAssertEqual(header.envelopeClass, .data)
        }
        XCTAssertEqual(Set(wire.map(\.recordName)), [try wireName("workbench-1"), try wireName("workbench-2")])
        let opened = try dataSaves().map(\.record)
        XCTAssertEqual(Set(opened.map(\.recordName)), ["workbench-1", "workbench-2"])
        XCTAssertEqual(opened.first { $0.recordName == "workbench-2" }?.notifyLevel, "high", "the level rides inside")
    }

    func testAnUnchangedTickSendsNothingDespiteRandomNonces() async throws {
        let source = StubSliceSource(kind: .workbench)
        let payload = Data(#"{"name":"acme"}"#.utf8)
        source.setPayload(payload, id: "1")
        let publisher = makePublisher([source])

        try await publisher.publishOnce()
        let second = try await publisher.publishOnce()

        XCTAssertEqual(second.pushed, 0, "the hash is of the plaintext, not of the envelope")
        XCTAssertEqual(wireSaves().count, 1)
        XCTAssertEqual(try state.hashes(forKind: .workbench), ["workbench-1": SliceDiff.hashHex(payload)])

        // The same plaintext sealed again is a different envelope (fresh nonce): a hash of the wire would never match.
        try state.wipeSyncState(now: Date())
        try await publisher.publishOnce()
        let envelopes = wireSaves().map(\.payload)
        XCTAssertEqual(envelopes.count, 2)
        XCTAssertNotEqual(envelopes[0], envelopes[1])
    }

    func testARecordThatCannotBeSealedIsSkippedAloneAndUnhashed() async throws {
        let source = StubSliceSource(kind: .deviceGrant)
        let grant = Data(#"{"linked":true}"#.utf8)
        let unknown = UUID().uuidString
        source.setRecords([
            // No agreement key for this device: no keybox recipient.
            SliceRecord(kind: .deviceGrant, id: unknown, modifiedAt: Date(), payload: grant),
            SliceRecord(kind: .deviceGrant, id: TestE2E.deviceID.uuidString, modifiedAt: Date(), payload: grant)
        ])
        let publisher = makePublisher([source])

        let result = try await publisher.publishOnce()
        try await publisher.publishOnce()

        XCTAssertEqual(result.pushed, 1, "one bad record never blocks the others")
        XCTAssertEqual(result.skipped, [SliceKind.deviceGrant.recordName(id: unknown)])
        XCTAssertEqual(wireSaves().map(\.recordName), [Keybox.recordName(deviceID: TestE2E.deviceID.uuidString)])
        XCTAssertEqual(
            Array(try state.hashes(forKind: .deviceGrant).keys),
            [SliceKind.deviceGrant.recordName(id: TestE2E.deviceID.uuidString)],
            "the unsealable record is not hashed, so it is retried"
        )
        XCTAssertEqual(publisher.sealWarnings, 1, "an unchanged unsealable record warns once")
    }

    func testWithoutHubKeysNothingIsPublished() async throws {
        let source = StubSliceSource(kind: .workbench)
        source.setPayload(Data("{}".utf8))
        let publisher = SlicePublisher(dbPool: dbPool, state: state, transport: nil, sources: [source])

        let result = try await publisher.publishOnce()

        XCTAssertEqual(result, SlicePublisher.Outcome())
        XCTAssertTrue(transport.saved.isEmpty, "never a plaintext fallback")
        XCTAssertEqual(source.reads, 0)
        XCTAssertNil(publisher.lastPublishAt)
        let heartbeat = CloudRecordFactory.record(for: SliceRecord(kind: .heartbeat, id: "x", modifiedAt: Date(), payload: Data()))
        do {
            try await publisher.saveHeartbeat(heartbeat)
            XCTFail("the heartbeat needs the hub keys too")
        } catch SlicePublisher.KeysError.unavailable {}
    }

    // MARK: - Sealed-size guard (D12, Review Focus 3)

    /// The cap is on the sealed envelope (header, padded frame, tag, signature), never on the payload alone: a
    /// frame exactly at `frameCap` pads to nothing and seals to exactly `Envelope.maxBytes`; one byte more does
    /// not fit even unpadded and is skipped, unhashed, warned once.
    func testARecordThatFitsOnlyUnpaddedStillPublishesAndOneThatDoesNotIsSkipped() async throws {
        let cap = EnvelopeSealer.frameCap(signed: true)
        let fitting = cap - InnerFrame(kind: "workbench", id: "workbench-fits", payload: Data()).encodedLength
        let fits = StubSliceSource(kind: .workbench)
        fits.setPayload(Data(repeating: 0x61, count: fitting), id: "fits")
        let over = StubSliceSource(kind: .workbenchTarget)
        let overOverhead = InnerFrame(kind: "workbench_target", id: "workbench_target-over", payload: Data()).encodedLength
        over.setPayload(Data(repeating: 0x61, count: cap - overOverhead + 1), id: "over")
        let empty = StubSliceSource(kind: .workbenchComment)
        empty.setPayload(Data(), id: "empty")
        let publisher = makePublisher([fits, over, empty])

        let result = try await publisher.publishOnce()
        try await publisher.publishOnce()

        XCTAssertEqual(result.pushed, 2)
        XCTAssertEqual(result.skipped, ["workbench_target-over"])
        let fitsWire = try wireName("workbench-fits")
        let sealed = try XCTUnwrap(wireSaves().first { $0.recordName == fitsWire })
        XCTAssertEqual(sealed.payload.count, Envelope.maxBytes, "the padding was clipped to the cap")
        XCTAssertLessThanOrEqual(wireSaves().map(\.payload.count).max() ?? 0, SlicePublisher.maxPayloadBytes)
        XCTAssertEqual(Set(try dataSaves().map(\.record.recordName)), ["workbench-fits", "workbench_comment-empty"])
        XCTAssertTrue(try state.hashes(forKind: .workbenchTarget).isEmpty, "an oversized record is not hashed")
        XCTAssertEqual(publisher.oversizedWarnings, 1, "warned once")
        let atCap = SliceRecord(kind: .workbench, id: "fits", modifiedAt: Date(), payload: Data(count: fitting))
        let overCap = SliceRecord(kind: .workbench, id: "fits", modifiedAt: Date(), payload: Data(count: fitting + 1))
        XCTAssertFalse(SlicePublisher.isOversized(atCap, signed: true))
        XCTAssertTrue(SlicePublisher.isOversized(overCap, signed: true))
        XCTAssertFalse(SlicePublisher.isOversized(overCap, signed: false), "an unsigned envelope has 64 bytes more room")
        XCTAssertTrue(SlicePublisher.isOversized(atCap, signed: true, hasAsset: true), "a descriptor takes 101 bytes")
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

    // MARK: - Epoch rotation (Task 14)

    /// A record published under epoch e that left the window while the epoch rotated is deleted at the next cycle:
    /// the rotation blanks the hashes instead of forgetting what the zone holds.
    func testARecordThatLeftTheWindowAcrossARotationIsDeletedAtTheNextCycle() async throws {
        let keyring = try state.testKeyring()
        let source = StubSliceSource(kind: .workbench)
        source.setRecords([
            SliceRecord(kind: .workbench, id: "1", modifiedAt: Date(), payload: Data(#"{"name":"acme"}"#.utf8)),
            SliceRecord(kind: .workbench, id: "2", modifiedAt: Date(), payload: Data(#"{"name":"beta"}"#.utf8))
        ])
        let publisher = makePublisher([source])
        _ = try await publisher.publishOnce()
        let before = try await openedRecords(in: transport)
        XCTAssertEqual(Set(before.map(\.recordName)), ["workbench-1", "workbench-2"])

        try keyring.rotate(reason: .manual)
        source.setRecords([
            SliceRecord(kind: .workbench, id: "1", modifiedAt: Date(), payload: Data(#"{"name":"acme"}"#.utf8))
        ])
        let outcome = try await publisher.publishOnce()

        XCTAssertEqual(outcome.pushed, 1, "the record still in the window is resealed")
        XCTAssertEqual(outcome.deleted, 1)
        let after = try await openedRecords(in: transport)
        XCTAssertEqual(after.map(\.recordName), ["workbench-1"], "no orphan is left")
        XCTAssertEqual(Array(try state.hashes(forKind: .workbench).keys), ["workbench-1"])
    }

    /// A cycle that sealed under epoch e before a rotation committed saves nothing, neither the records nor a fresh
    /// alert's signal: the next cycle seals them under e+1.
    func testACycleThatSealedBeforeARotationCommittedSavesNothing() async throws {
        let keyring = try state.testKeyring()
        let keys = RotatingKeys(keyring)
        let workbenches = StubSliceSource(kind: .workbench)
        workbenches.setPayload(Data(#"{"name":"acme"}"#.utf8))
        let alerts = StubSliceSource(kind: .askAlert)
        alerts.setPayload(Data(#"{"ask_id":7}"#.utf8), id: "7")
        let publisher = SlicePublisher(
            dbPool: dbPool, state: state,
            transport: SecureTransport(inner: transport, keys: keys, rollback: keyring, names: state),
            sources: [workbenches, alerts])
        keys.onSign = { try? keyring.rotate(reason: .manual) }

        let aborted = try await publisher.publishOnce()

        XCTAssertEqual(try keyring.currentEpoch(), 2, "the rotation committed while the cycle sealed")
        XCTAssertEqual(aborted.pushed, 0)
        XCTAssertTrue(transport.saved.isEmpty, "nothing sealed under epoch 1 is saved, no signal either")

        _ = try await publisher.publishOnce()
        let saved = transport.saved.map(\.record)
        let envelopes = saved.filter { $0.kind == WireKind.envelope }
        XCTAssertEqual(envelopes.count, 2)
        XCTAssertEqual(try envelopes.map { try Envelope.parse($0.payload).header.epoch }, [2, 2])
        XCTAssertEqual(saved.filter { $0.kind == WireKind.signal }.count, 1, "the alert's one signal")
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
            dbPool: dbPool, state: state, transport: transport.sealing(), sources: [], timing: .standard
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
            dbPool: dbPool, state: state, transport: transport.sealing(), sources: [source],
            timing: .init(tick: .seconds(60), fastWindow: .milliseconds(50), fastSpacing: .milliseconds(100)),
            sendNow: { await transport.sendNow() } // swiftlint:disable:this trailing_closure
        )
        publisher.start()
        defer { publisher.stop() }
        await awaitHubCondition("the start cycle (the tick) publishes") {
            ((try? self.dataSaves().count) ?? 0) == 1 && publisher.lastPublishAt != nil
        }
        XCTAssertEqual(transport.sendNowCalls, 0, "the tick leaves the send to CKSyncEngine")

        publisher.nudge(kinds: [.workbench])
        await awaitHubCondition("an unchanged fast cycle finished") { publisher.fastCyclesCompleted == 1 }
        XCTAssertEqual(source.reads, 2)
        XCTAssertEqual(transport.sendNowCalls, 0, "an empty fast diff sends nothing")

        source.setPayload(Data(#"{"v":2}"#.utf8))
        publisher.nudge(kinds: [.workbench])
        await awaitHubCondition("the changed record is sent at once") { transport.sendNowCalls == 1 }
        XCTAssertEqual(try dataSaves().count, 2)
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
        SlicePublisher(dbPool: dbPool, state: state, transport: transport.sealing(names: state), sources: [source], assets: store)
    }

    func testAnAssetRecordIsStagedAndSavedWithItsFile() async throws {
        try await withAssetStore { store in
            let source = StubAssetSliceSource()
            source.set(id: "7", payload: #"{"id":7}"#, asset: "[1]")
            let result = try await assetPublisher(source, store: store).publishOnce()

            XCTAssertEqual(result.pushed, 1)
            let saved = try XCTUnwrap(try dataSaves().last?.record)
            let file = try XCTUnwrap(saved.assetFileURL, "the asset rides as the record's CKAsset")
            XCTAssertEqual(file, store.fileURL(recordName: "meeting_transcript-7", fileName: "segments.json"))
            XCTAssertNotEqual(try Data(contentsOf: file), Data("[1]".utf8), "the staged file is ciphertext")
            XCTAssertEqual(try TestOpening.assetPlaintext(saved), Data("[1]".utf8), "it opens with the frame's descriptor")
            XCTAssertEqual(saved.payload, Data(#"{"id":7}"#.utf8), "the asset is not in the payload")
            let wire = try XCTUnwrap(wireSaves().last)
            XCTAssertTrue(try Envelope.parse(wire.payload).header.flags.contains(.hasAsset))
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
            XCTAssertEqual(try TestOpening.assetPlaintext(try XCTUnwrap(try dataSaves().last?.record)), Data("[2]".utf8))
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).sorted(),
                ["segments.json", "segments.json.desc"],
                "replaced in place: the sealed file and its descriptor, nothing else"
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
                ((try? self.dataSaves().count) ?? 0) == 2 && store.isStaged(recordName: "meeting_transcript-7", fileName: "segments.json")
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

/// The hub keyring, with a hook run once when the hub signs (each DataZone seal signs after reading its epoch and
/// key): a rotation committing between a record's seal and its save.
final class RotatingKeys: SecureKeyProvider, @unchecked Sendable {
    private let base: HubKeyring
    private let lock = NSLock()
    private var hook: (() -> Void)?

    init(_ base: HubKeyring) { self.base = base }

    /// Runs once, at the next `hubSigner()`.
    var onSign: (() -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue } }
    }

    var role: SecureRole { base.role }
    func metaKey() throws -> SymmetricKey { try base.metaKey() }
    func currentEpoch() throws -> UInt32 { try base.currentEpoch() }
    func dataKey(epoch: UInt32) throws -> SymmetricKey { try base.dataKey(epoch: epoch) }
    func alertKey(epoch: UInt32) throws -> SymmetricKey { try base.alertKey(epoch: epoch) }
    func relayKey(_ direction: RelayDirection, deviceID: UUID, epoch: UInt32) throws -> SymmetricKey {
        try base.relayKey(direction, deviceID: deviceID, epoch: epoch)
    }
    func acceptsRelayEpoch(_ epoch: UInt32, deviceID: UUID) throws -> Bool { try base.acceptsRelayEpoch(epoch, deviceID: deviceID) }
    func relayDeviceIDs() throws -> [UUID] { try base.relayDeviceIDs() }
    func nextSeq() throws -> UInt64 { try base.nextSeq() }
    func hubSigner() throws -> Curve25519.Signing.PrivateKey {
        let run = lock.withLock { () -> (() -> Void)? in
            defer { hook = nil }
            return hook
        }
        run?()
        return try base.hubSigner()
    }
    func hubAgreement() throws -> Curve25519.KeyAgreement.PrivateKey { try base.hubAgreement() }
    func keyboxRecipient(deviceID: UUID) throws -> Curve25519.KeyAgreement.PublicKey? {
        try base.keyboxRecipient(deviceID: deviceID)
    }
    func deviceSigner() throws -> Curve25519.Signing.PrivateKey { try base.deviceSigner() }
    func hubAgreementPublicKey() throws -> Curve25519.KeyAgreement.PublicKey { try base.hubAgreementPublicKey() }
    func linkNonce() throws -> Data { try base.linkNonce() }
}

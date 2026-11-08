import os
import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// The feed across a weekly key rotation (relay client Phase 5, "The phone's rule for a relay key" and "What a
/// dropped or parked record costs"): a record in an epoch above the phone's newest waits for its keybox, at most
/// `keyboxWaitCap`, then the feed parks and loses nothing; a hub record in an epoch the phone will never hold is
/// dropped, and every unechoed action is queued again once per batch.
extension RelayFeedTests {
    /// Counts the feed's fetches (its `pull` hook runs once per fetching cycle).
    private final class Fetches: @unchecked Sendable {
        struct Offline: Error {}
        private let lock = NSLock()
        private var count = 0
        private var failing = false
        var value: Int { lock.withLock { count } }
        /// While set, each fetch fails as a network error would.
        var offline: Bool {
            get { lock.withLock { failing } }
            set { lock.withLock { failing = newValue } }
        }
        func hit() throws {
            try lock.withLock {
                count += 1
                if failing { throw Offline() }
            }
        }
    }

    private struct Rotation {
        let rig: OrderedRig
        let clock: OSAllocatedUnfairLock<Date>
        let fetches: Fetches

        func advance(by seconds: TimeInterval) {
            clock.withLock { $0 = $0.addingTimeInterval(seconds) }
        }

        /// The test hub seals what it writes next in `epoch` (static keys, as a hub with no offer of this phone).
        func hubSeals(in epoch: UInt32) {
            rig.hub.keys.currentEpochValue = epoch
        }

        /// One cycle that waits for a keybox: it throws `keysUnavailable`, as a lock does.
        func pollWaiting(file: StaticString = #filePath, line: UInt = #line) async {
            do {
                _ = try await rig.feed.pollOnce()
                XCTFail("the cycle waits for the keybox", file: file, line: line)
            } catch SecureTransportError.keysUnavailable {
            } catch {
                XCTFail("unexpected \(error)", file: file, line: line)
            }
        }
    }

    /// The paired phone with an ephemeral link holding `epochs`, over the ordered rig, on a movable clock.
    private func rotation(epochs: [UInt32]) async throws -> Rotation {
        let clock = OSAllocatedUnfairLock(initialState: OrderedRig.base)
        let fetches = Fetches()
        let rig = try await OrderedRig.make(now: { clock.withLock { $0 } }, pull: { try fetches.hit() })
        try EphemeralLink.make(rig.keys, epochs: epochs)
        return Rotation(rig: rig, clock: clock, fetches: fetches)
    }

    // MARK: - An epoch above the newest (F15, F26)

    func testAnEchoAboveTheNewestEpochWaitsForTheKeybox() async throws {
        let r = try await rotation(epochs: [1])
        try await r.rig.insert()
        _ = try await r.rig.outbox.flush()
        r.hubSeals(in: 2)
        try await r.rig.hub.sync()
        let token = try r.rig.store.relayToken()

        do {
            _ = try await r.rig.phone.changes(in: .relay, since: token)
            XCTFail("an epoch above the newest waits")
        } catch SecureTransportError.keysUnavailable {}
        await r.pollWaiting()
        XCTAssertEqual(try r.rig.store.relayToken(), token, "the token is kept")
        XCTAssertEqual(try r.rig.rows().map(\.delivery), [.sent], "nothing was routed")

        try EphemeralLink.add(r.rig.keys, epoch: 2)
        let routed = try await r.rig.feed.pollOnce()

        XCTAssertEqual(routed, 1, "the replay after the merge opens the echo")
        XCTAssertTrue(try r.rig.rows().isEmpty)
        XCTAssertNotEqual(try r.rig.store.relayToken(), token)
    }

    func testAMergeClearsTheWaitSince() async throws {
        let r = try await rotation(epochs: [1])
        r.hubSeals(in: 2)
        try await r.rig.hub.writeControl(await r.rig.hub.control(.transportSwitchRejected))
        await r.pollWaiting()
        XCTAssertEqual(try r.rig.store.relayWaitSince(), OrderedRig.base)

        r.advance(by: 600)
        await r.pollWaiting()
        XCTAssertEqual(try r.rig.store.relayWaitSince(), OrderedRig.base, "the first sighting stays")

        try EphemeralLink.add(r.rig.keys, epoch: 2)
        _ = try await r.rig.feed.pollOnce()
        XCTAssertNil(try r.rig.store.relayWaitSince())
    }

    func testAPendingEpochParksAfterTheCapAndLosesNothing() async throws {
        let r = try await rotation(epochs: [1])
        try await r.rig.insert()
        try await r.rig.insert()
        _ = try await r.rig.outbox.flush()
        let written = await r.rig.recorder.conditionalSaves.count
        // A resend_from the phone can open sits behind one in an epoch it cannot open yet.
        r.hubSeals(in: 2)
        let pending = await r.rig.hub.control(.resendFrom, seq: 2)
        try await r.rig.hub.writeControl(pending)
        r.hubSeals(in: 1)
        let behind = await r.rig.hub.control(.resendFrom, seq: 1)
        try await r.rig.hub.writeControl(behind)
        let token = try r.rig.store.relayToken()

        await r.pollWaiting()
        r.advance(by: SecureTransport.keyboxWaitCap - 1)
        await r.pollWaiting()
        XCTAssertNil(try r.rig.store.relayFeedParkedSince(), "not parked within the cap")
        r.advance(by: 1)
        await r.pollWaiting()
        let parkedAt = OrderedRig.base.addingTimeInterval(SecureTransport.keyboxWaitCap)
        XCTAssertEqual(try r.rig.store.relayFeedParkedSince(), parkedAt)
        let fetched = r.fetches.value

        r.advance(by: 86_400)
        let idle = try await r.rig.feed.pollOnce()
        XCTAssertEqual(idle, 0)
        XCTAssertEqual(r.fetches.value, fetched, "a parked feed does not fetch")
        XCTAssertEqual(try r.rig.store.relayToken(), token, "parking keeps the token")
        XCTAssertFalse(try r.rig.store.isControlHandled(id: behind.id), "nothing behind the pending record is skipped")
        let idleSaves = await r.rig.recorder.conditionalSaves.count
        XCTAssertEqual(idleSaves, written)

        try EphemeralLink.add(r.rig.keys, epoch: 2)
        await r.rig.feed.resumeIfParked()
        _ = try await r.rig.feed.pollOnce()

        XCTAssertTrue(try r.rig.store.isControlHandled(id: pending.id))
        XCTAssertTrue(try r.rig.store.isControlHandled(id: behind.id), "read, in order, after the merge")
        let saves = await r.rig.recorder.conditionalSaves
        XCTAssertEqual(
            saves.dropFirst(written).map(\.names), [[try r.rig.wire(2)], [try r.rig.wire(1)], [try r.rig.wire(2)]],
            "resend_from(2), then resend_from(1)")
        XCTAssertNil(try r.rig.store.relayFeedParkedSince())
        XCTAssertNil(try r.rig.store.relayWaitSince())
    }

    func testParkingWritesTheMetaKeyAndAnOpeningReadRemovesIt() async throws {
        let r = try await rotation(epochs: [1])
        r.hubSeals(in: 2)
        try await r.rig.hub.writeControl(await r.rig.hub.control(.transportSwitchRejected))
        await r.pollWaiting()
        XCTAssertNil(try r.rig.store.relayFeedParkedSince())
        r.advance(by: SecureTransport.keyboxWaitCap)
        await r.pollWaiting()
        let mark = try await r.rig.store.reader.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM replica_meta WHERE key = 'relay_feed_parked_since'")
        }
        XCTAssertNotNil(mark)

        await r.rig.feed.resumeIfParked()
        XCTAssertNotNil(try r.rig.store.relayFeedParkedSince(), "a resume alone keeps the mark")
        XCTAssertNotNil(try r.rig.store.relayWaitSince(), "a resume is no merge: the first sighting stays")

        try EphemeralLink.add(r.rig.keys, epoch: 2)
        _ = try await r.rig.feed.pollOnce()
        XCTAssertNil(try r.rig.store.relayFeedParkedSince(), "the read that opens removes it")
        XCTAssertNil(try r.rig.store.relayWaitSince())
    }

    /// Parks the rig's feed on a record of epoch 2; returns the mark.
    private func parked(_ r: Rotation) async throws -> Date {
        r.hubSeals(in: 2)
        try await r.rig.hub.writeControl(await r.rig.hub.control(.transportSwitchRejected))
        await r.pollWaiting()
        r.advance(by: SecureTransport.keyboxWaitCap)
        await r.pollWaiting()
        return try XCTUnwrap(r.rig.store.relayFeedParkedSince())
    }

    func testAForegroundWithNoNewKeysKeepsTheMarkAndItsSince() async throws {
        let r = try await rotation(epochs: [1])
        let mark = try await parked(r)
        r.advance(by: 3_600)
        let fetched = r.fetches.value

        await r.rig.feed.resumeIfParked()
        await r.pollWaiting()

        XCTAssertEqual(r.fetches.value, fetched + 1, "the foreground reads once")
        XCTAssertEqual(try r.rig.store.relayFeedParkedSince(), mark, "no flicker: the mark and its since stay")
    }

    func testAForegroundWhileOfflineKeepsTheMark() async throws {
        let r = try await rotation(epochs: [1])
        let mark = try await parked(r)
        r.fetches.offline = true

        await r.rig.feed.resumeIfParked()
        do {
            _ = try await r.rig.feed.pollOnce()
            XCTFail("offline")
        } catch is Fetches.Offline {}

        XCTAssertEqual(try r.rig.store.relayFeedParkedSince(), mark, "Now keeps the row while the actions still wait")
    }

    /// F26/F38: the hour runs from the first sighting, locked hours included. A phone locked and woken in the
    /// background in the middle of the wait keeps its sighting, and the first read after unlock past the hour parks.
    func testALockedThenWokenPhoneParksAfterTheHour() async throws {
        let r = try await rotation(epochs: [1])
        r.hubSeals(in: 2)
        try await r.rig.hub.writeControl(await r.rig.hub.control(.transportSwitchRejected))
        await r.pollWaiting()
        XCTAssertEqual(try r.rig.store.relayWaitSince(), OrderedRig.base)

        r.rig.keys.isLocked = true
        r.advance(by: 1_800)
        await r.pollWaiting()
        XCTAssertEqual(try r.rig.store.relayWaitSince(), OrderedRig.base, "a locked background cycle keeps the sighting")
        XCTAssertNil(try r.rig.store.relayFeedParkedSince())
        r.advance(by: 1_800)
        r.rig.keys.isLocked = false
        await r.pollWaiting()

        XCTAssertEqual(
            try r.rig.store.relayFeedParkedSince(), OrderedRig.base.addingTimeInterval(SecureTransport.keyboxWaitCap),
            "parked: Now shows S58")
    }

    /// Blocks the key-source check until released, telling when the feed reached it.
    private final class BlockingCheck: @unchecked Sendable {
        private let lock = NSLock()
        private var reached = false
        private let release = DispatchSemaphore(value: 0)
        var hasReached: Bool { lock.withLock { reached } }

        func check() -> Bool {
            lock.withLock { reached = true }
            _ = release.wait(timeout: .now() + 10)
            return true
        }

        func open() { release.signal() }
    }

    /// I1: a resume sent while a cycle is deciding whether to park, at the key-source check, is not lost: the check
    /// and the park run with no suspension, so the resume lands after the park and wins.
    func testAResumeWhileTheKeySourceIsCheckedIsNotLost() async throws {
        let r = try await rotation(epochs: [1])
        r.hubSeals(in: 2)
        try await r.rig.hub.writeControl(await r.rig.hub.control(.transportSwitchRejected))
        await r.pollWaiting()
        r.advance(by: SecureTransport.keyboxWaitCap)
        let blocking = BlockingCheck()
        r.rig.phone.setWaitsForKeybox { blocking.check() }

        let running = Task { _ = try? await r.rig.feed.pollOnce() }
        while !blocking.hasReached { await Task.yield() }
        let resume = Task { await r.rig.feed.resumeIfParked() }
        await Task.yield()
        blocking.open()
        await running.value
        await resume.value
        r.rig.phone.setWaitsForKeybox { true }
        let fetched = r.fetches.value

        try EphemeralLink.add(r.rig.keys, epoch: 2)
        _ = try await r.rig.feed.pollOnce()

        XCTAssertEqual(r.fetches.value, fetched + 1, "the merge's resume stands: the feed reads")
        XCTAssertNil(try r.rig.store.relayFeedParkedSince(), "and the opening read removes the mark")
    }

    func testResumeIfParkedFetchesAgain() async throws {
        let r = try await rotation(epochs: [1])
        r.hubSeals(in: 2)
        try await r.rig.hub.writeControl(await r.rig.hub.control(.transportSwitchRejected))
        await r.pollWaiting()
        r.advance(by: SecureTransport.keyboxWaitCap)
        await r.pollWaiting()
        _ = try await r.rig.feed.pollOnce()
        let parked = r.fetches.value

        await r.rig.feed.resumeIfParked()
        await r.pollWaiting()

        XCTAssertEqual(r.fetches.value, parked + 1, "a foreground reads once more")
        XCTAssertNotNil(try r.rig.store.relayFeedParkedSince(), "still waiting past the cap: parked again")
        _ = try await r.rig.feed.pollOnce()
        XCTAssertEqual(r.fetches.value, parked + 1)
    }

    /// Holds the feed's fetch at its `pull` hook until released.
    private actor PullGate {
        private var entered: CheckedContinuation<Void, Never>?
        private var hasEntered = false
        private var release: CheckedContinuation<Void, Never>?
        private var armed = false

        func arm() { armed = true }

        func pass() async {
            guard armed else { return }
            armed = false
            hasEntered = true
            entered?.resume()
            await withCheckedContinuation { release = $0 }
        }

        func waitUntilEntered() async {
            if hasEntered { return }
            await withCheckedContinuation { entered = $0 }
        }

        func open() { release?.resume() }
    }

    /// A merge's resume that lands while a read started before the keys came is not undone by that read's park.
    func testAResumeDuringARunningReadIsNotLost() async throws {
        let clock = OSAllocatedUnfairLock(initialState: OrderedRig.base)
        let gate = PullGate()
        let rig = try await OrderedRig.make(now: { clock.withLock { $0 } }, pull: { await gate.pass() })
        try EphemeralLink.make(rig.keys, epochs: [1])
        rig.hub.keys.currentEpochValue = 2
        try await rig.hub.writeControl(await rig.hub.control(.transportSwitchRejected))
        do { _ = try await rig.feed.pollOnce() } catch SecureTransportError.keysUnavailable {}
        clock.withLock { $0 = $0.addingTimeInterval(SecureTransport.keyboxWaitCap) }

        await gate.arm()
        let running = Task { try await rig.feed.pollOnce() }
        await gate.waitUntilEntered()
        await rig.feed.resumeIfParked()
        await gate.open()
        do { _ = try await running.value } catch SecureTransportError.keysUnavailable {}

        XCTAssertNil(try rig.store.relayFeedParkedSince(), "the resume came during the read: no park")
        try EphemeralLink.add(rig.keys, epoch: 2)
        _ = try await rig.feed.pollOnce()
        XCTAssertNil(try rig.store.relayWaitSince(), "the next cycle reads, and opens")
    }

    /// A launch reads once (the parked state is in memory); a record still waiting past the cap parks it again.
    func testALaunchReadsOnceAndParksAgainWhileTheRecordWaits() async throws {
        let r = try await rotation(epochs: [1])
        r.hubSeals(in: 2)
        try await r.rig.hub.writeControl(await r.rig.hub.control(.transportSwitchRejected))
        await r.pollWaiting()
        r.advance(by: SecureTransport.keyboxWaitCap)
        await r.pollWaiting()
        let parkedAt = try r.rig.store.relayFeedParkedSince()
        let fetched = r.fetches.value

        let relaunched = RelayFeed(
            transport: r.rig.phone, store: r.rig.store, outbox: r.rig.outbox, pull: { try r.fetches.hit() },
            now: { r.clock.withLock { $0 } })
        do { _ = try await relaunched.pollOnce() } catch SecureTransportError.keysUnavailable {}
        _ = try await relaunched.pollOnce()

        XCTAssertEqual(r.fetches.value, fetched + 1, "one read at launch, then parked again")
        XCTAssertEqual(try r.rig.store.relayFeedParkedSince(), parkedAt, "the first mark stays")
    }

    func testNoKeySourceStopsTheFeedSilently() async throws {
        let r = try await rotation(epochs: [1])
        r.rig.phone.setWaitsForKeybox { false }
        r.hubSeals(in: 2)
        try await r.rig.hub.writeControl(await r.rig.hub.control(.transportSwitchRejected))
        let token = try r.rig.store.relayToken()

        await r.pollWaiting()
        let stopped = r.fetches.value
        for _ in 0..<3 { _ = try await r.rig.feed.pollOnce() }

        XCTAssertEqual(r.fetches.value, stopped, "no fetch until a merge, a foreground or a launch")
        XCTAssertEqual(try r.rig.store.relayToken(), token)
        XCTAssertNil(try r.rig.store.relayFeedParkedSince(), "no parked mark: Now shows nothing")
        XCTAssertNil(try r.rig.store.relayWaitSince())

        // A launch builds a new feed: it reads again.
        let relaunched = RelayFeed(transport: r.rig.phone, store: r.rig.store, outbox: r.rig.outbox) { try r.fetches.hit() }
        do { _ = try await relaunched.pollOnce() } catch SecureTransportError.keysUnavailable {}
        XCTAssertEqual(r.fetches.value, stopped + 1)
        await r.rig.feed.resumeIfParked()
        do { _ = try await r.rig.feed.pollOnce() } catch SecureTransportError.keysUnavailable {}
        XCTAssertEqual(r.fetches.value, stopped + 2)
    }

    func testARotationDoesNotSweepTheReplica() async throws {
        let r = try await rotation(epochs: [1])
        let sliceRecord = CloudRecord(
            recordName: SliceKind.target.recordName(id: "7"), zone: .data, kind: SliceKind.target.rawValue,
            modifiedAt: OrderedRig.base, payload: Data(#"{"id":"7"}"#.utf8))
        try r.rig.store.apply(CloudChangeBatch(
            changed: [try TestE2E.sealedDataRecord(sliceRecord, seq: 1)], deletedRecordNames: [],
            newToken: CloudChangeToken(value: 1)))
        r.hubSeals(in: 2)
        try await r.rig.hub.writeControl(await r.rig.hub.control(.transportSwitchRejected))
        await r.pollWaiting()

        try EphemeralLink.add(r.rig.keys, epoch: 2)
        _ = try await r.rig.feed.pollOnce()

        XCTAssertFalse(try r.rig.store.sweepsAfterFullPull(), "a rotation is no route move")
        XCTAssertNotNil(try r.rig.store.storedToken(), "the data token stays")
        let rows = try await r.rig.store.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") }
        XCTAssertEqual(rows, 1)
    }

    // MARK: - An epoch the phone will never hold (F16)

    func testARelayRecordInAGoneEpochIsDroppedNotReplayed() async throws {
        let keys = try TestE2E.phoneStore()
        try EphemeralLink.make(keys, epochs: [2, 3])
        let inner = InMemoryCloudTransport()
        let rejected = OSAllocatedUnfairLock(initialState: [String]())
        let transport = SecureTransport(
            inner: inner, keys: try TestE2E.phone(store: keys), rollback: InMemoryRollbackGuard()
        ) { _, reason in rejected.withLock { $0.append(reason) } }
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let outbox = ActionOutbox(transport: transport, store: store, deviceID: TestE2E.deviceID.uuidString)
        let feed = RelayFeed(transport: transport, store: store, outbox: outbox)
        _ = try await outbox.enqueue(kind: .targetDone, entityRecordName: "target-1")
        let action = try XCTUnwrap(store.pendingActions().first).action
        var echo = action
        echo.status = .applied
        let record = try CloudRecordFactory.record(for: echo, modifiedAt: OrderedRig.base)
        try await TestE2E.hubTransport(TestE2E.hub(epoch: 1), inner: inner).save([record])

        let routed = try await feed.pollOnce()

        XCTAssertEqual(routed, 0, "dropped, never routed")
        XCTAssertEqual(rejected.withLock { $0 }, ["epochGone"])
        let token = try XCTUnwrap(store.relayToken(), "the batch finished and the token moved")
        let again = try await feed.pollOnce()
        XCTAssertEqual(again, 0)
        XCTAssertEqual(try store.relayToken(), token, "not replayed")
        XCTAssertEqual(try store.pendingActions().map(\.state), [.pending])
    }

    func testADroppedEchoQueuesTheUnechoedAgain() async throws {
        let r = try await rotation(epochs: [2, 3])
        _ = try await r.rig.outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
        _ = try await r.rig.outbox.flush()
        // The hub applies it and echoes in an epoch this phone no longer holds.
        r.hubSeals(in: 1)
        try await r.rig.hub.sync()
        let echoRecord = try await r.rig.mailbox().first
        let echoVersion = try XCTUnwrap(echoRecord?.recordSeq)
        let before = await r.rig.recorder.conditionalSaves.count

        _ = try await r.rig.feed.pollOnce()
        await r.rig.outbox.drain()

        let saves = await r.rig.recorder.conditionalSaves.dropFirst(before)
        XCTAssertEqual(saves.map(\.names), [[try r.rig.wire(1)], [try r.rig.wire(1)]])
        XCTAssertEqual(saves.last?.expects, [.seq(echoVersion)], "the unreadable echo is overwritten under its version (sim rule 3)")
        let row = try XCTUnwrap(r.rig.rows().first)
        XCTAssertEqual(row.delivery, .sent)
        let onWire = try await r.rig.mailbox().first?.payload
        XCTAssertEqual(onWire, row.envelope, "the action is back in its record")

        // The hub reads it as a repeat and echoes it again, now in an epoch the phone holds.
        r.hubSeals(in: 3)
        try await r.rig.hub.sync()
        _ = try await r.rig.feed.pollOnce()
        XCTAssertTrue(try r.rig.rows().isEmpty, "the repeat's echo settles the row")
        let applied = await r.rig.hub.applied
        XCTAssertEqual(applied, [1], "applied once")
    }

    func testADroppedResendFromRecoversByResending() async throws {
        let r = try await rotation(epochs: [2, 3])
        try await r.rig.insert()
        try await r.rig.insert()
        _ = try await r.rig.outbox.flush()
        let before = await r.rig.recorder.conditionalSaves.count
        r.hubSeals(in: 1)
        let resend = await r.rig.hub.control(.resendFrom, seq: 1)
        try await r.rig.hub.writeControl(resend)

        _ = try await r.rig.feed.pollOnce()
        await r.rig.outbox.drain()

        XCTAssertFalse(try r.rig.store.isControlHandled(id: resend.id), "the resend_from itself is never read")
        let saves = await r.rig.recorder.conditionalSaves
        XCTAssertEqual(saves.dropFirst(before).map(\.names), [[try r.rig.wire(1)], [try r.rig.wire(2)]], "the same resend")
        XCTAssertEqual(try r.rig.rows().map(\.delivery), [.sent, .sent])
    }

    /// The dropped `transport_switched` is never handed over; the transport marker on the next sync carries the move
    /// (rule 12a), pinned by the sim twin `testMarkerLeadsReturningPhone` and Go's `TestMarkerLeadsReturningPhone`.
    func testADroppedSwitchIsNeverHandedOver() async throws {
        let r = try await rotation(epochs: [2, 3])
        let handled = OSAllocatedUnfairLock(initialState: 0)
        await r.rig.feed.setTransportHandler { _ in
            handled.withLock { $0 += 1 }
            return true
        }
        r.hubSeals(in: 1)
        let switched = await r.rig.hub.control(.transportSwitched)
        try await r.rig.hub.writeControl(switched)

        _ = try await r.rig.feed.pollOnce()

        XCTAssertEqual(handled.withLock { $0 }, 0, "dropped: the transport marker on the next sync carries the move (rule 12a)")
        XCTAssertFalse(try r.rig.store.isControlHandled(id: switched.id))
        XCTAssertNotNil(try r.rig.store.relayToken(), "the feed moves on")
        _ = try await r.rig.feed.pollOnce()
        XCTAssertEqual(handled.withLock { $0 }, 0, "never handed again")
    }

    func testTwoDropsInABatchRequeueOnce() async throws {
        let r = try await rotation(epochs: [2, 3])
        try await r.rig.insert()
        try await r.rig.insert()
        _ = try await r.rig.outbox.flush()
        let before = await r.rig.recorder.conditionalSaves.count
        r.hubSeals(in: 1)
        try await r.rig.hub.writeControl(await r.rig.hub.control(.resendFrom, seq: 1))
        try await r.rig.hub.writeControl(await r.rig.hub.control(.transportSwitched))

        _ = try await r.rig.feed.pollOnce()
        await r.rig.outbox.drain()

        let saves = await r.rig.recorder.conditionalSaves
        XCTAssertEqual(saves.dropFirst(before).map(\.names), [[try r.rig.wire(1)], [try r.rig.wire(2)]], "one requeue, one pass")
    }
}

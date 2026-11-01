import GRDB
import os
import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// The ordered path of `ActionOutbox` (relay client Phase 1, Task 6): gapless seqs, the single-flight flush (sim
/// rules 1, 3, 7a), `resend_from` and `skip_to` (rules 5–6), the 24 h withdrawal (Ruling 5), Retry and Dismiss All.
/// The phone's `SecureTransport` runs over a recording wrapper of one `InMemoryCloudTransport`; the test hub writes
/// its echoes into the same zone.
final class ActionOutboxOrderedTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let day: TimeInterval = 86_400
    private var device: String { TestE2E.deviceID.uuidString }
    private var hubID: String { TestE2E.hubID.uuidString }

    private struct Phone {
        let inner: InMemoryCloudTransport
        let recorder: RecordingConditionalTransport
        let secure: SecureTransport
        let hub: SecureTransport
        let store: ReplicaStore
        let outbox: ActionOutbox
        let clock: OSAllocatedUnfairLock<Date>
        let keys: InMemoryPhoneKeyStore

        func advance(by seconds: TimeInterval) {
            clock.withLock { $0 = $0.addingTimeInterval(seconds) }
        }
    }

    private func makePhone(ordered: Bool = true, route: HubRoute = .cloudKit(.private)) async throws -> Phone {
        let keys = try TestE2E.phoneStore()
        let inner = InMemoryCloudTransport()
        let recorder = RecordingConditionalTransport(inner: inner)
        let secure = TestE2E.phoneTransport(try TestE2E.phone(store: keys), inner: recorder)
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let clock = OSAllocatedUnfairLock(initialState: base)
        let outbox = ActionOutbox(transport: secure, store: store, deviceID: device, route: route) {
            clock.withLock { $0 }
        }
        if ordered { try await outbox.enableOrderedActions() }
        await outbox.setHubID(hubID)
        return Phone(
            inner: inner, recorder: recorder, secure: secure, hub: TestE2E.hubTransport(inner: inner), store: store,
            outbox: outbox, clock: clock, keys: keys)
    }

    // MARK: - Helpers

    private func wire(_ phone: Phone, _ seq: UInt64) throws -> String {
        try phone.secure.wireName(
            plain: ActionRequestPayload.orderedRecordName(deviceID: TestE2E.deviceID, actionSeq: seq), zone: .relay)
    }

    /// Inserts the next ordered row straight into the replica (no flush), sealed as the outbox seals it.
    @discardableResult
    private func insert(
        _ phone: Phone, params: [String: JSONValue] = [:], createdAt: Date? = nil
    ) async throws -> (id: String, seq: UInt64) {
        let seq = try phone.store.nextActionSeq()
        let action = ActionRequestPayload(
            id: UUID().uuidString, kind: .targetDone, entityID: "42", params: params, createdAt: createdAt ?? base,
            deviceID: device, hubID: hubID)
        let sealed = try await phone.secure.seal(try CloudRecordFactory.orderedRecord(
            for: action, actionSeq: seq, deviceID: TestE2E.deviceID, modifiedAt: action.createdAt))
        XCTAssertTrue(try phone.store.insertOrderedAction(
            action, entityRecordName: "target-42", sealed: sealed, epoch: try Envelope.parse(sealed.payload).header.epoch,
            seq: seq))
        return (action.id, seq)
    }

    private func echo(
        _ id: String, seq: UInt64, status: ActionStatus, reason: ActionReason? = nil, message: String? = nil
    ) -> ActionRequestPayload {
        var echo = ActionRequestPayload(
            id: id, kind: .targetDone, entityID: "42", createdAt: base, deviceID: device, hubID: hubID)
        echo.actionSeq = seq
        echo.status = status
        echo.reason = reason
        echo.errorMessage = message
        return echo
    }

    /// The hub writes its echo over the action's record (an unconditional save, a new version).
    private func hubWrites(_ phone: Phone, _ echo: ActionRequestPayload) async throws {
        let seq = try XCTUnwrap(echo.actionSeq)
        try await phone.hub.save([CloudRecordFactory.orderedRecord(
            for: echo, actionSeq: seq, deviceID: TestE2E.deviceID, modifiedAt: base)])
    }

    private func current(_ phone: Phone, _ wireName: String) async throws -> CloudRecord? {
        try await phone.inner.changes(in: .relay, since: nil).changed.first { $0.recordName == wireName }
    }

    private func row(_ phone: Phone, _ id: String) throws -> OutboxRow? {
        try phone.store.outboxRows([.queued, .sent, .settled, .undelivered]).first { $0.actionID == id }
    }

    private func pending(_ phone: Phone, _ id: String) throws -> PendingAction? {
        try phone.store.pendingActions().first { $0.id == id }
    }

    private func saves(_ phone: Phone) async -> [RecordingConditionalTransport.Save] {
        await phone.recorder.conditionalSaves
    }

    /// The controls the phone wrote, opened with its own key.
    private func writtenControls(_ phone: Phone) async throws -> [ControlPayload] {
        try await phone.secure.changes(in: .relay, since: nil).changed
            .filter { $0.kind == RelayRecordKind.control.rawValue }
            .map { try RelayCoder.makeDecoder().decode(ControlPayload.self, from: $0.payload) }
    }

    /// Hops onto the outbox actor a few times so a task started just before has entered it.
    private func settle(_ phone: Phone) async throws {
        for _ in 0..<5 {
            await Task.yield()
            _ = try await phone.outbox.orderedActions()
        }
    }

    // MARK: - Legacy and enqueue

    func testALegacyHubKeepsTodaysPath() async throws {
        let phone = try await makePhone(ordered: false)
        let id = try await phone.outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
        _ = try await phone.outbox.flush()

        let calls = await phone.recorder.calls
        XCTAssertEqual(calls, [.plainSave([try phone.secure.wireName(plain: "action-\(id)", zone: .relay)])])
        let opened = try await phone.secure.changes(in: .relay, since: nil).changed
        let action = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: try XCTUnwrap(opened.first).payload)
        XCTAssertNil(action.actionSeq)
        XCTAssertNil(action.hubID, "the legacy payload is unchanged")
        XCTAssertEqual(action.deviceID, device)
        XCTAssertTrue(try phone.store.queuedControls().isEmpty)
        let row = try XCTUnwrap(pending(phone, id))
        XCTAssertNil(row.actionSeq)
        XCTAssertNil(row.delivery)
    }

    func testOrderedEnqueueWritesAGaplessSeriesInOrder() async throws {
        let phone = try await makePhone()
        var ids: [String] = []
        for _ in 0..<3 {
            ids.append(try await phone.outbox.enqueue(kind: .targetDone, entityRecordName: "target-42"))
        }
        _ = try await phone.outbox.flush()

        let saves = await saves(phone)
        XCTAssertEqual(saves.map(\.names), [[try wire(phone, 1)], [try wire(phone, 2)], [try wire(phone, 3)]])
        XCTAssertEqual(saves.map(\.expects), Array(repeating: [.absent], count: 3))
        let rows = try phone.store.outboxRows([.queued, .sent, .settled, .undelivered])
        XCTAssertEqual(rows.map(\.actionID), ids)
        XCTAssertEqual(rows.map(\.actionSeq), [1, 2, 3])
        XCTAssertEqual(rows.map(\.delivery), [.sent, .sent, .sent])
        XCTAssertEqual(rows.map(\.epoch), [1, 1, 1])
        XCTAssertTrue(rows.allSatisfy { $0.recordSeq != nil })

        let opened = try await phone.secure.changes(in: .relay, since: nil).changed
        let payloads = try opened.map { try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: $0.payload) }
        XCTAssertEqual(payloads.map(\.actionSeq), [1, 2, 3])
        XCTAssertEqual(Set(payloads.map(\.hubID)), [hubID])
        XCTAssertEqual(Set(payloads.map(\.status)), [.pending])
    }

    func testTwoConcurrentEnqueuesGetConsecutiveSeqs() async throws {
        let phone = try await makePhone()
        async let first = phone.outbox.enqueue(kind: .targetDone, entityRecordName: "target-1")
        async let second = phone.outbox.enqueue(kind: .targetDone, entityRecordName: "target-2")
        let ids = try await [first, second]
        _ = try await phone.outbox.flush()

        let rows = try phone.store.outboxRows([.queued, .sent, .settled, .undelivered])
        XCTAssertEqual(Set(rows.map(\.actionID)), Set(ids))
        XCTAssertEqual(rows.map(\.actionSeq), [1, 2])
        XCTAssertEqual(try phone.store.nextActionSeq(), 3)
        XCTAssertEqual(rows.map(\.delivery), [.sent, .sent])
    }

    // MARK: - The flush

    func testATransientRefusalStopsTheFlushAndTheNextPassResumes() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        let two = try await insert(phone)
        let three = try await insert(phone)
        let inner = phone.inner
        await phone.recorder.beforeSave(1) { await inner.refuseNext(.unreachable, count: 1) }

        let report = try await phone.outbox.flush()

        XCTAssertEqual(report, OutboxFlushReport(written: 1, stoppedOn: .unreachable, undelivered: 0))
        XCTAssertEqual(try row(phone, one.id)?.delivery, .sent)
        XCTAssertEqual(try row(phone, two.id)?.delivery, .queued)
        XCTAssertEqual(try row(phone, three.id)?.delivery, .queued)
        let firstPass = await saves(phone)
        XCTAssertEqual(firstPass.map(\.names), [[try wire(phone, 1)], [try wire(phone, 2)]], "3 never attempted")

        let next = try await phone.outbox.flush()
        XCTAssertEqual(next, OutboxFlushReport(written: 2, stoppedOn: nil, undelivered: 0))
        let all = await saves(phone)
        XCTAssertEqual(all.dropFirst(2).map(\.names), [[try wire(phone, 2)], [try wire(phone, 3)]])
        XCTAssertEqual(try row(phone, three.id)?.delivery, .sent)
    }

    func testAPermanentRefusalListsTheActionAsNotDelivered() async throws {
        let phone = try await makePhone()
        try await insert(phone)
        let two = try await insert(phone)
        let three = try await insert(phone)
        let inner = phone.inner
        await phone.recorder.beforeSave(1) { await inner.refuseNext(.permanent(code: "zoneNotFound"), count: 1) }

        let report = try await phone.outbox.flush()

        XCTAssertEqual(report, OutboxFlushReport(written: 2, stoppedOn: nil, undelivered: 1))
        let listed = try XCTUnwrap(pending(phone, two.id))
        XCTAssertEqual(listed.delivery, .undelivered)
        XCTAssertEqual(listed.undeliveredReason, .refused)
        XCTAssertEqual(listed.state, .failed)
        XCTAssertEqual(listed.errorMessage, "Not delivered to your Mac.")
        XCTAssertEqual(try row(phone, three.id)?.delivery, .sent, "the pass goes on")
    }

    /// The conflict's current record does not open (garbage here): the phone cannot tell what is there, so the row
    /// stays queued, nothing is overwritten, and the next pass tries again.
    func testAConflictThatCannotBeReadLeavesTheRowForTheNextPass() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        let two = try await insert(phone)
        try await phone.inner.save([CloudRecord(
            recordName: try wire(phone, 1), zone: .relay, kind: WireKind.envelope, modifiedAt: base,
            payload: Data([1, 2, 3]))])

        let report = try await phone.outbox.flush()

        XCTAssertEqual(report, OutboxFlushReport(written: 1, stoppedOn: nil, undelivered: 0))
        XCTAssertEqual(try row(phone, one.id)?.delivery, .queued)
        XCTAssertEqual(try row(phone, two.id)?.delivery, .sent)
        let left = try await current(phone, try wire(phone, 1))
        XCTAssertEqual(left?.payload, Data([1, 2, 3]), "not overwritten")

        _ = try await phone.outbox.flush()
        let all = await saves(phone)
        XCTAssertEqual(all.map(\.names), [[try wire(phone, 1)], [try wire(phone, 2)], [try wire(phone, 1)]])
    }

    func testAConflictWithIdenticalBytesCountsAsSent() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        let stored = try XCTUnwrap(row(phone, one.id))
        try await phone.inner.save([CloudRecord(
            recordName: stored.wireName, zone: .relay, kind: WireKind.envelope, modifiedAt: base,
            payload: stored.envelope)])
        let version = try await current(phone, stored.wireName)?.recordSeq

        let report = try await phone.outbox.flush()

        XCTAssertEqual(report.written, 1)
        let saves = await saves(phone)
        XCTAssertEqual(saves.count, 1, "no overwrite")
        XCTAssertEqual(try row(phone, one.id)?.delivery, .sent)
        XCTAssertEqual(try row(phone, one.id)?.recordSeq, version)
    }

    func testAConflictWithTheHubsEchoSettlesTheRow() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        try await hubWrites(phone, echo(one.id, seq: 1, status: .failed, reason: .notFound, message: "gone on the Mac"))

        _ = try await phone.outbox.flush()

        let saves = await saves(phone)
        XCTAssertEqual(saves.count, 1, "the hub's echo is never overwritten")
        let settled = try XCTUnwrap(pending(phone, one.id))
        XCTAssertEqual(settled.delivery, .settled)
        XCTAssertEqual(settled.state, .failed)
        XCTAssertEqual(settled.errorMessage, "gone on the Mac")
        XCTAssertEqual(settled.reason, .notFound)
    }

    func testAConflictWithAnythingElseIsOverwrittenUnderItsSeq() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        let stored = try XCTUnwrap(row(phone, one.id))
        // An earlier copy of the same action, sealed again: other bytes under the same name.
        let action = try XCTUnwrap(pending(phone, one.id)).action
        let copy = try await phone.secure.seal(try CloudRecordFactory.orderedRecord(
            for: action, actionSeq: 1, deviceID: TestE2E.deviceID, modifiedAt: base))
        XCTAssertNotEqual(copy.payload, stored.envelope)
        try await phone.inner.save([copy])
        let earlier = try await current(phone, stored.wireName)
        let version = try XCTUnwrap(earlier?.recordSeq)

        _ = try await phone.outbox.flush()

        let saves = await saves(phone)
        XCTAssertEqual(saves.map(\.expects), [[.absent], [.seq(version)]])
        let now = try await current(phone, stored.wireName)
        XCTAssertEqual(now?.payload, stored.envelope)
        XCTAssertEqual(try row(phone, one.id)?.delivery, .sent)
        XCTAssertEqual(try row(phone, one.id)?.recordSeq, now?.recordSeq)
    }

    func testTwoFlushRequestsNeverOverlap() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        let gate = await phone.inner.suspendNextSave()
        let outbox = phone.outbox
        let first = Task { try await outbox.flush() }
        await gate.waitUntilReached()
        let two = try await insert(phone)
        let second = Task { try await outbox.flush() }
        try await settle(phone)

        let during = await phone.recorder.events
        XCTAssertEqual(during, ["save"], "the second flush waits for the first")
        gate.open()
        _ = try await first.value
        _ = try await second.value

        let events = await phone.recorder.events
        XCTAssertEqual(events, ["save", "saved", "save", "saved"])
        XCTAssertEqual(try row(phone, one.id)?.delivery, .sent)
        XCTAssertEqual(try row(phone, two.id)?.delivery, .sent)
    }

    /// `drain()` returns once every operation on the chain has ended: the running flush and the one queued after it.
    func testDrainWaitsForTheWholeChain() async throws {
        let phone = try await makePhone()
        try await insert(phone)
        let gate = await phone.inner.suspendNextSave()
        let outbox = phone.outbox
        let first = Task { try await outbox.flush() }
        await gate.waitUntilReached()
        try await insert(phone)
        let second = Task { try await outbox.flush() }
        try await settle(phone)
        let drained = OSAllocatedUnfairLock(initialState: false)
        let draining = Task {
            await outbox.drain()
            drained.withLock { $0 = true }
        }
        try await settle(phone)
        XCTAssertFalse(drained.withLock { $0 }, "a flush is still running")

        gate.open()
        await draining.value

        let events = await phone.recorder.events
        XCTAssertEqual(events, ["save", "saved", "save", "saved"], "both passes ended before drain returned")
        _ = try await first.value
        _ = try await second.value
    }

    /// Every flush pass reaches the report observer: the ones an enqueue or `resend_from` starts as well as an
    /// explicit `flush()`, so the phone's "last flush stopped" line never misses one.
    func testEveryFlushReachesTheReportObserver() async throws {
        let phone = try await makePhone()
        let reports = OSAllocatedUnfairLock(initialState: [OutboxFlushReport]())
        await phone.outbox.setFlushReportObserver { report in reports.withLock { $0.append(report) } }
        await phone.inner.refuseNext(.unreachable, count: 1)

        _ = try await phone.outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
        _ = try await phone.outbox.sweepSilentPending()
        XCTAssertEqual(reports.withLock { $0 }, [OutboxFlushReport(stoppedOn: .unreachable)], "the enqueue's own flush")

        _ = try await phone.outbox.flush()
        try await phone.outbox.resendFrom(1)
        XCTAssertEqual(reports.withLock { $0 }.count, 3)
        XCTAssertEqual(reports.withLock { $0 }.dropFirst().map(\.stoppedOn), [nil, nil])
    }

    // MARK: - Echoes

    func testAGapHoldLeavesTheOverlayAlone() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        _ = try await phone.outbox.flush()

        let final = try await phone.outbox.applyEcho(echo(one.id, seq: 1, status: .held))

        XCTAssertFalse(final)
        let row = try XCTUnwrap(pending(phone, one.id))
        XCTAssertNil(row.echoStatus)
        XCTAssertNil(row.reason)
        XCTAssertEqual(row.state, .pending)
        XCTAssertEqual(row.delivery, .sent)

        // A held line (with its reason) is recorded as today.
        try await phone.outbox.applyEcho(echo(one.id, seq: 1, status: .held, reason: .agentBusy))
        XCTAssertEqual(try pending(phone, one.id)?.echoStatus, .held)
        XCTAssertEqual(try pending(phone, one.id)?.reason, .agentBusy)
    }

    func testAnyEchoOfAQueuedRowMakesItSent() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)

        try await phone.outbox.applyEcho(echo(one.id, seq: 1, status: .received))

        XCTAssertEqual(try pending(phone, one.id)?.delivery, .sent)
        XCTAssertEqual(try pending(phone, one.id)?.echoStatus, .received)
    }

    /// A final echo settles a sent row (never through `dismissAction`, which refuses a row on its way): `applied`
    /// removes it and tells the observer, a failure settles it. Only an ordered final echo reads as final.
    func testAFinalEchoSettlesASentRow() async throws {
        let phone = try await makePhone()
        let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
        await phone.outbox.setAppliedObserver { action in seen.withLock { $0.append(action.id) } }
        let one = try await insert(phone)
        let two = try await insert(phone)
        _ = try await phone.outbox.flush()

        let applied = try await phone.outbox.applyEcho(echo(one.id, seq: 1, status: .applied))
        let failed = try await phone.outbox.applyEcho(echo(two.id, seq: 2, status: .expired, reason: .expired))

        XCTAssertTrue(applied)
        XCTAssertTrue(failed)
        XCTAssertNil(try pending(phone, one.id))
        XCTAssertEqual(seen.withLock { $0 }, [one.id])
        let settled = try XCTUnwrap(pending(phone, two.id))
        XCTAssertEqual(settled.delivery, .settled)
        XCTAssertEqual(settled.state, .failed)
        XCTAssertEqual(settled.errorMessage, ActionOutbox.noMessageFallback)

        var legacy = echo("legacy", seq: 1, status: .applied)
        legacy.actionSeq = nil
        let legacyFinal = try await phone.outbox.applyEcho(legacy)
        XCTAssertFalse(legacyFinal, "a legacy echo is never deleted by the feed")
    }

    func testAnEchoOfAnUndeliveredRowLeavesTheList() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        let two = try await insert(phone)
        await phone.inner.refuseNext(.permanent(code: "zoneNotFound"), count: 2)
        _ = try await phone.outbox.flush()
        XCTAssertEqual(try phone.store.outboxRows([.undelivered]).count, 2)

        try await phone.outbox.applyEcho(echo(one.id, seq: 1, status: .applied))
        try await phone.outbox.applyEcho(echo(two.id, seq: 2, status: .failed, message: "refused on the Mac"))

        XCTAssertNil(try pending(phone, one.id))
        let settled = try XCTUnwrap(pending(phone, two.id))
        XCTAssertEqual(settled.delivery, .settled)
        XCTAssertEqual(settled.errorMessage, "refused on the Mac")
        XCTAssertNil(settled.undeliveredReason)
        XCTAssertTrue(try phone.store.outboxRows([.undelivered]).isEmpty)
    }

    // MARK: - resend_from

    func testAResendFromDuringAFlushIsAppliedAfterIt() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        let gate = await phone.inner.suspendNextSave()
        let outbox = phone.outbox
        let flush = Task { try await outbox.flush() }
        await gate.waitUntilReached()
        let resend = Task { try await outbox.resendFrom(1) }
        try await settle(phone)
        XCTAssertEqual(try row(phone, one.id)?.delivery, .queued, "the flush still holds row 1")

        gate.open()
        _ = try await flush.value
        try await resend.value

        let saves = await saves(phone)
        XCTAssertEqual(saves.map(\.names), [[try wire(phone, 1)], [try wire(phone, 1)]], "written twice")
        let first = try XCTUnwrap(saves.first?.expects.first)
        XCTAssertEqual(first, .absent)
        guard case .seq = try XCTUnwrap(saves.last?.expects.first) else {
            return XCTFail("the resend writes a new version")
        }
        XCTAssertEqual(try row(phone, one.id)?.delivery, .sent)
    }

    func testResendFromRequeuesFromTheGap() async throws {
        let phone = try await makePhone()
        try await insert(phone)
        try await insert(phone)
        try await insert(phone)
        _ = try await phone.outbox.flush()
        let versions = try phone.store.outboxRows([.sent]).map { try XCTUnwrap($0.recordSeq) }

        try await phone.outbox.resendFrom(2)

        let saves = await saves(phone)
        XCTAssertEqual(saves.dropFirst(3).map(\.names), [[try wire(phone, 2)], [try wire(phone, 3)]])
        XCTAssertEqual(saves.dropFirst(3).map(\.expects), [[.seq(versions[1])], [.seq(versions[2])]])
        XCTAssertTrue(try phone.store.queuedControls().isEmpty, "nothing to skip")
        let controls = try await writtenControls(phone)
        XCTAssertTrue(controls.isEmpty)
        XCTAssertEqual(try phone.store.outboxRows([.sent]).count, 3)
    }

    func testAResendWritesANewVersionOfARecordThatStillExists() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        _ = try await phone.outbox.flush()
        let written = try XCTUnwrap(row(phone, one.id))
        let version = try XCTUnwrap(written.recordSeq)
        let token = try await phone.inner.changes(in: .relay, since: nil).newToken

        try await phone.outbox.resendFrom(1)

        let after = try XCTUnwrap(row(phone, one.id))
        XCTAssertGreaterThan(try XCTUnwrap(after.recordSeq), version)
        XCTAssertEqual(after.delivery, .sent)
        let changed = try await phone.inner.changes(in: .relay, since: token).changed
        let again = try XCTUnwrap(changed.first { $0.recordName == written.wireName }, "listed in changes again")
        XCTAssertEqual(again.payload, written.envelope, "the same envelope bytes")
    }

    func testAResendThatMeetsTheHubsEchoAppliesIt() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        _ = try await phone.outbox.flush()
        try await hubWrites(phone, echo(one.id, seq: 1, status: .applied))
        let echoBytes = try await current(phone, try wire(phone, 1))?.payload

        try await phone.outbox.resendFrom(1)

        XCTAssertNil(try pending(phone, one.id), "applied: settled and gone")
        let saves = await saves(phone)
        XCTAssertEqual(saves.count, 2, "one resend write, no rewrite")
        let after = try await current(phone, try wire(phone, 1))
        XCTAssertEqual(after?.payload, echoBytes)
    }

    func testAResendThatMeetsAHeldEchoRewritesTheAction() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        _ = try await phone.outbox.flush()
        let stored = try XCTUnwrap(row(phone, one.id))
        try await hubWrites(phone, echo(one.id, seq: 1, status: .held))
        let echoRecord = try await current(phone, stored.wireName)
        let held = try XCTUnwrap(echoRecord?.recordSeq)

        try await phone.outbox.resendFrom(1)

        let saves = await saves(phone)
        XCTAssertEqual(saves.dropFirst().map(\.expects), [[.seq(try XCTUnwrap(stored.recordSeq))], [.seq(held)]])
        let now = try await current(phone, stored.wireName)
        XCTAssertEqual(now?.payload, stored.envelope, "the action's original bytes")
        let after = try XCTUnwrap(pending(phone, one.id))
        XCTAssertEqual(after.delivery, .sent)
        XCTAssertNil(after.echoStatus, "a gap hold changes no overlay")
        XCTAssertEqual(try row(phone, one.id)?.recordSeq, now?.recordSeq)
    }

    private struct CloudKitPhone {
        let outbox: ActionOutbox
        let replica: ReplicaStore
        let database: FakeConditionalDatabase
        let written: OutboxRow
        let clock: OSAllocatedUnfairLock<Date>

        func row() throws -> OutboxRow? {
            try replica.outboxRows([.queued, .sent, .settled, .undelivered]).first { $0.actionID == written.actionID }
        }
    }

    /// An ordered phone over `CloudKitTransport` whose one action was written (stored version 1), then the hub's
    /// held echo fetched over it (stored version 2), applied by the feed and compacted out of the buffer: the
    /// local buffer holds no current copy of the record.
    private func cloudKitPhoneWithACompactedHeldEcho() async throws -> CloudKitPhone {
        let transportStore = try TransportStore.inMemory()
        let database = FakeConditionalDatabase()
        let cloudKit = CloudKitTransport.conditionalTesting(store: transportStore, database: database)
        let zones = HubZones(scope: .shared(ownerName: "_owner-acme"), hubID: HubZones.testHubID)
        let keys = try TestE2E.phoneStore()
        let secure = TestE2E.phoneTransport(try TestE2E.phone(store: keys), inner: cloudKit)
        let replica = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let clock = OSAllocatedUnfairLock(initialState: base)
        let outbox = ActionOutbox(transport: secure, store: replica, deviceID: device) { clock.withLock { $0 } }
        try await outbox.enableOrderedActions()
        await outbox.setHubID(hubID)

        let id = try await outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
        _ = try await outbox.flush()
        let written = try XCTUnwrap(replica.outboxRows([.sent]).first { $0.actionID == id })
        XCTAssertEqual(written.recordSeq, 1)

        // The hub's held echo over the action's record, fetched into the buffer as the engine would.
        let hubInner = InMemoryCloudTransport()
        let held = echo(id, seq: 1, status: .held)
        try await TestE2E.hubTransport(inner: hubInner).save([CloudRecordFactory.orderedRecord(
            for: held, actionSeq: 1, deviceID: TestE2E.deviceID, modifiedAt: base)])
        let hubChanges = try await hubInner.changes(in: .relay, since: nil)
        let sealedEcho = try XCTUnwrap(hubChanges.changed.first)
        XCTAssertEqual(sealedEcho.recordName, written.wireName)
        let echoRecord = database.seed(CloudKitTransport.ckRecord(
            from: sealedEcho, in: zones.zoneID(for: .relay), systemFields: nil))
        try transportStore.bufferFetched(
            changed: [try XCTUnwrap(CloudKitTransport.cloudRecord(from: echoRecord, zone: .relay))],
            systemFields: [(name: written.wireName, zone: .relay, data: CloudKitTransport.archivedSystemFields(of: echoRecord))],
            deleted: [:])
        // The feed applied it, then compacted the buffer.
        try await outbox.applyOrderedEcho(held)
        try transportStore.compactEvents(in: .relay, keepSince: try transportStore.changes(in: .relay, since: nil).newToken)
        return CloudKitPhone(outbox: outbox, replica: replica, database: database, written: written, clock: clock)
    }

    /// On CloudKit, after the held echo was compacted: the resend reads the echo from the server and rewrites it;
    /// the row is never listed as Not delivered (a Retry would apply it twice).
    func testAResendOnCloudKitAfterTheHeldEchoWasCompactedRewritesIt() async throws {
        let phone = try await cloudKitPhoneWithACompactedHeldEcho()

        try await phone.outbox.resendFrom(1)

        XCTAssertEqual(try phone.row()?.delivery, .sent, "never listed as Not delivered")
        XCTAssertEqual(phone.database.record(named: phone.written.wireName)?.encryptedValues["payload"] as? Data,
                       phone.written.envelope, "the held echo is rewritten with the action")
    }

    /// On CloudKit, after the held echo was compacted, the record is gone on the server (hub hygiene): the 24 h
    /// withdrawal counts it as deleted and lists the row once, instead of retrying at every sweep.
    func testAWithdrawalOnCloudKitOfARecordGoneOnTheServerListsTheRow() async throws {
        let phone = try await cloudKitPhoneWithACompactedHeldEcho()
        let id = try XCTUnwrap(phone.database.record(named: phone.written.wireName)?.recordID)
        _ = try await phone.database.modify(saving: [], deleting: [id])
        phone.clock.withLock { $0 = $0.addingTimeInterval(25 * 3600) }

        let swept = try await phone.outbox.sweepSilentPending()

        XCTAssertEqual(swept, [phone.written.actionID])
        let after = try XCTUnwrap(try phone.row())
        XCTAssertEqual(after.delivery, .undelivered)
        XCTAssertEqual(try phone.replica.pendingActions().first?.undeliveredReason, .noAnswer)
    }

    func testAResendOverwriteThatMeetsAFinalEchoSettlesTheRow() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        _ = try await phone.outbox.flush()
        try await hubWrites(phone, echo(one.id, seq: 1, status: .held))
        let final = echo(one.id, seq: 1, status: .failed, message: "too late")
        let hub = phone.hub
        // The hub answers between the resend's write and its overwrite of the held echo.
        await phone.recorder.beforeSave(2) {
            try await hub.save([CloudRecordFactory.orderedRecord(
                for: final, actionSeq: 1, deviceID: TestE2E.deviceID, modifiedAt: self.base)])
        }

        try await phone.outbox.resendFrom(1)

        let saves = await saves(phone)
        XCTAssertEqual(saves.count, 3, "no third write")
        let settled = try XCTUnwrap(pending(phone, one.id))
        XCTAssertEqual(settled.delivery, .settled)
        XCTAssertEqual(settled.errorMessage, "too late")
    }

    func testAResendOfAGoneRecordWritesItAgainAsNew() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        _ = try await phone.outbox.flush()
        let stored = try XCTUnwrap(row(phone, one.id))
        try await phone.inner.delete(recordNames: [stored.wireName], in: .relay)

        try await phone.outbox.resendFrom(1)

        let saves = await saves(phone)
        XCTAssertEqual(saves.dropFirst().map(\.expects), [[.seq(try XCTUnwrap(stored.recordSeq))], [.absent]])
        let again = try await current(phone, stored.wireName)
        XCTAssertEqual(again?.payload, stored.envelope)
        XCTAssertEqual(try row(phone, one.id)?.delivery, .sent)
    }

    /// A row marked sent without a version (a conflict's record carried none) is rewritten by the first-write rules.
    func testASentRowWithoutAVersionIsRewrittenAsNew() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        try phone.store.markSent(actionID: one.id, recordSeq: nil, at: base)
        XCTAssertNil(try row(phone, one.id)?.recordSeq)

        try await phone.outbox.resendFrom(1)

        let saves = await saves(phone)
        XCTAssertEqual(saves.map(\.expects), [[.absent]])
        XCTAssertEqual(try row(phone, one.id)?.delivery, .sent)
        XCTAssertNotNil(try row(phone, one.id)?.recordSeq)
    }

    /// A first write that meets the hub's held echo keeps the echo's version, so the next resend rewrites it.
    func testAFirstWriteThatMeetsAHeldEchoKeepsItsVersionForTheResend() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        let stored = try XCTUnwrap(row(phone, one.id))
        try await hubWrites(phone, echo(one.id, seq: 1, status: .held, reason: .agentBusy))
        let echoRecord = try await current(phone, stored.wireName)
        let held = try XCTUnwrap(echoRecord?.recordSeq)

        _ = try await phone.outbox.flush()
        XCTAssertEqual(try row(phone, one.id)?.recordSeq, held)
        XCTAssertEqual(try pending(phone, one.id)?.echoStatus, .held)

        try await phone.outbox.resendFrom(1)

        let saves = await saves(phone)
        XCTAssertEqual(saves.map(\.expects), [[.absent], [.seq(held)]])
        let now = try await current(phone, stored.wireName)
        XCTAssertEqual(now?.payload, stored.envelope, "the held echo is rewritten with the action")
        XCTAssertEqual(try row(phone, one.id)?.recordSeq, now?.recordSeq)
    }

    /// A requeued row with no known version: our own bytes found at another version are written again as a new one.
    func testARequeuedRowWithoutAVersionRewritesItsOwnBytes() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        let stored = try XCTUnwrap(row(phone, one.id))
        try await phone.inner.save([CloudRecord(
            recordName: stored.wireName, zone: .relay, kind: WireKind.envelope, modifiedAt: base,
            payload: stored.envelope)])
        let earlier = try await current(phone, stored.wireName)
        let version = try XCTUnwrap(earlier?.recordSeq)
        try phone.store.markSent(actionID: one.id, recordSeq: nil, at: base)

        try await phone.outbox.resendFrom(1)

        let saves = await saves(phone)
        XCTAssertEqual(saves.map(\.expects), [[.absent], [.seq(version)]])
        let now = try await current(phone, stored.wireName)
        XCTAssertEqual(now?.payload, stored.envelope)
        XCTAssertGreaterThan(try XCTUnwrap(now?.recordSeq), version, "a new version the hub lists again")
        XCTAssertEqual(try row(phone, one.id)?.recordSeq, now?.recordSeq)
        XCTAssertEqual(try row(phone, one.id)?.delivery, .sent)
    }

    /// A requeued row with no known version that meets a held echo rewrites it once.
    func testARequeuedRowWithoutAVersionRewritesAHeldEcho() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        let stored = try XCTUnwrap(row(phone, one.id))
        try phone.store.markSent(actionID: one.id, recordSeq: nil, at: base)
        try await hubWrites(phone, echo(one.id, seq: 1, status: .held))
        let echoRecord = try await current(phone, stored.wireName)
        let held = try XCTUnwrap(echoRecord?.recordSeq)

        try await phone.outbox.resendFrom(1)

        let saves = await saves(phone)
        XCTAssertEqual(saves.map(\.expects), [[.absent], [.seq(held)]])
        let now = try await current(phone, stored.wireName)
        XCTAssertEqual(now?.payload, stored.envelope)
        XCTAssertEqual(try row(phone, one.id)?.delivery, .sent)
        XCTAssertEqual(try row(phone, one.id)?.recordSeq, now?.recordSeq)
    }

    func testResendFromSkipsWhatItCannotSendAndListsNothingNew() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        let two = try await insert(phone)
        let three = try await insert(phone)
        await phone.inner.refuseNext(.permanent(code: "zoneNotFound"), count: 1)
        _ = try await phone.outbox.flush()
        try await phone.outbox.applyEcho(echo(two.id, seq: 2, status: .failed, message: "no"))

        try await phone.outbox.resendFrom(1)

        let controls = try await writtenControls(phone)
        XCTAssertEqual(controls.count, 1)
        let skip = try XCTUnwrap(controls.first)
        XCTAssertEqual(skip.kind, .skipTo)
        XCTAssertEqual(skip.seq, 3)
        XCTAssertEqual(skip.deviceID, device)
        XCTAssertEqual(skip.deviceID, skip.deviceID?.uppercased())
        XCTAssertEqual(skip.hubID, hubID)
        XCTAssertTrue(try phone.store.queuedControls().isEmpty, "written")
        XCTAssertEqual(try pending(phone, one.id)?.undeliveredReason, .refused)
        XCTAssertEqual(try pending(phone, two.id)?.delivery, .settled)
        XCTAssertEqual(try phone.store.outboxRows([.undelivered]).map(\.actionID), [one.id], "nothing new listed")
        XCTAssertEqual(try row(phone, three.id)?.delivery, .sent)
        let saves = await saves(phone)
        let controlWire = try phone.secure.wireName(plain: skip.recordName, zone: .relay)
        XCTAssertEqual(
            saves.suffix(2).map(\.names), [[controlWire], [try wire(phone, 3)]], "the control first, then row 3")
    }

    func testResendFromWithNoRowsWritesOnlySkipTo() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        let two = try await insert(phone)
        try await phone.outbox.applyEcho(echo(one.id, seq: 1, status: .applied))
        try await phone.outbox.applyEcho(echo(two.id, seq: 2, status: .applied))

        try await phone.outbox.resendFrom(1)

        let saves = await saves(phone)
        XCTAssertEqual(saves.count, 1, "the control alone")
        let controls = try await writtenControls(phone)
        XCTAssertEqual(controls.map(\.seq), [3])
    }

    // MARK: - Controls

    /// Rows 1–2 left through `applied` echoes, row 3 waits: `resendFrom(1)` queues `skip_to(3)` ahead of it.
    private func phoneWithASkipToAhead(
        route: HubRoute = .cloudKit(.private), refusal: TransportRefusal
    ) async throws -> (phone: Phone, row: String) {
        let phone = try await makePhone(route: route)
        let one = try await insert(phone)
        let two = try await insert(phone)
        try await phone.outbox.applyEcho(echo(one.id, seq: 1, status: .applied))
        try await phone.outbox.applyEcho(echo(two.id, seq: 2, status: .applied))
        let three = try await insert(phone)
        await phone.inner.refuseNext(refusal, count: 1)
        try await phone.outbox.resendFrom(1)
        return (phone, three.id)
    }

    func testARefusedControlIsKeptAndRetried() async throws {
        let (phone, row3) = try await phoneWithASkipToAhead(refusal: .unreachable)

        let control = try XCTUnwrap(try phone.store.queuedControls().first)
        XCTAssertEqual(control.kind, .skipTo)
        let firstPass = await saves(phone)
        XCTAssertEqual(firstPass.map(\.names), [[control.wireName]], "no action written in that pass")
        XCTAssertEqual(try row(phone, row3)?.delivery, .queued)

        let report = try await phone.outbox.flush()

        XCTAssertEqual(report, OutboxFlushReport(written: 2, stoppedOn: nil, undelivered: 0))
        XCTAssertTrue(try phone.store.queuedControls().isEmpty)
        XCTAssertEqual(try row(phone, row3)?.delivery, .sent)
        let controls = try await writtenControls(phone)
        XCTAssertEqual(controls.map(\.seq), [3])
    }

    func testAPermanentlyRefusedControlDoesNotBlockLaterActions() async throws {
        let (phone, row3) = try await phoneWithASkipToAhead(refusal: .permanent(code: "zoneNotFound"))

        let control = try XCTUnwrap(try phone.store.queuedControls().first)
        let firstPass = await saves(phone)
        XCTAssertEqual(firstPass.map(\.names), [[control.wireName], [try wire(phone, 3)]])
        XCTAssertEqual(try row(phone, row3)?.delivery, .sent, "attempted in the same pass")

        _ = try await phone.outbox.flush()

        XCTAssertTrue(try phone.store.queuedControls().isEmpty, "tried again and written on the next pass")
        let controls = try await writtenControls(phone)
        XCTAssertEqual(controls.map(\.seq), [3])
    }

    func testAControlIsNeverDroppedOnCloudKit() async throws {
        let (phone, _) = try await phoneWithASkipToAhead(route: .cloudKit(.private), refusal: .unreachable)

        phone.advance(by: 30 * day)
        await phone.inner.refuseNext(.unreachable, count: 1)
        _ = try await phone.outbox.flush()
        XCTAssertEqual(try phone.store.queuedControls().count, 1, "still queued after 30 days")

        _ = try await phone.outbox.flush()
        XCTAssertTrue(try phone.store.queuedControls().isEmpty)
        let controls = try await writtenControls(phone)
        XCTAssertEqual(controls.map(\.seq), [3])
    }

    func testAControlUnwrittenFor14DaysIsDroppedOnTheHostedRelay() async throws {
        let (phone, row3) = try await phoneWithASkipToAhead(
            route: .hostedRelay(macDeviceID: "mac-acme"), refusal: .unreachable)
        let control = try XCTUnwrap(try phone.store.queuedControls().first)

        phone.advance(by: 13 * day)
        await phone.inner.refuseNext(.unreachable, count: 1)
        _ = try await phone.outbox.flush()
        XCTAssertEqual(try phone.store.queuedControls().count, 1, "kept inside the relay's TTL")

        phone.advance(by: day + 1)
        _ = try await phone.outbox.flush()

        XCTAssertTrue(try phone.store.queuedControls().isEmpty, "dropped")
        let saves = await saves(phone)
        XCTAssertEqual(saves.filter { $0.names == [control.wireName] }.count, 2, "never written after the TTL")
        let controls = try await writtenControls(phone)
        XCTAssertTrue(controls.isEmpty)
        XCTAssertEqual(try row(phone, row3)?.delivery, .sent)
    }

    // MARK: - 24 h without an answer

    func testAQueuedRowOlderThan24HoursIsNotDelivered() async throws {
        let phone = try await makePhone()
        let old = try await insert(phone)
        let young = try await insert(phone, createdAt: base.addingTimeInterval(2 * 3600))
        phone.advance(by: day + 1)

        let swept = try await phone.outbox.sweepSilentPending()

        XCTAssertEqual(swept, [old.id])
        let listed = try XCTUnwrap(pending(phone, old.id))
        XCTAssertEqual(listed.delivery, .undelivered)
        XCTAssertEqual(listed.undeliveredReason, .noAnswer)
        XCTAssertEqual(listed.errorMessage, "No answer from your Mac for 24 hours.")
        XCTAssertEqual(try row(phone, young.id)?.delivery, .queued)
        let calls = await phone.recorder.calls
        XCTAssertTrue(calls.isEmpty, "a never-written row has nothing to withdraw")
    }

    func testASentRowOlderThan24HoursIsWithdrawnThenListed() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        _ = try await phone.outbox.flush()
        let stored = try XCTUnwrap(row(phone, one.id))
        phone.advance(by: day + 1)

        let swept = try await phone.outbox.sweepSilentPending()

        XCTAssertEqual(swept, [one.id])
        let deletes = await phone.recorder.conditionalDeletes
        XCTAssertEqual(deletes.map(\.names), [[stored.wireName]])
        XCTAssertEqual(deletes.map(\.expects), [[.seq(try XCTUnwrap(stored.recordSeq))]])
        let left = try await current(phone, stored.wireName)
        XCTAssertNil(left, "withdrawn")
        XCTAssertEqual(try pending(phone, one.id)?.undeliveredReason, .noAnswer)
    }

    func testAWithdrawalThatMeetsAnEchoSettlesInstead() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        _ = try await phone.outbox.flush()
        try await hubWrites(phone, echo(one.id, seq: 1, status: .failed, message: "late"))
        phone.advance(by: day + 1)

        let swept = try await phone.outbox.sweepSilentPending()

        XCTAssertTrue(swept.isEmpty)
        let settled = try XCTUnwrap(pending(phone, one.id))
        XCTAssertEqual(settled.delivery, .settled)
        XCTAssertEqual(settled.errorMessage, "late")
        let left = try await current(phone, try wire(phone, 1))
        XCTAssertNotNil(left, "the hub's echo stays")
    }

    func testUndeliveredRowsCarryWhyTheyWereListed() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        let two = try await insert(phone)
        await phone.inner.refuseNext(.permanent(code: "zoneNotFound"), count: 1)
        _ = try await phone.outbox.flush()
        phone.advance(by: day + 1)
        _ = try await phone.outbox.sweepSilentPending()
        let three = try await insert(phone, createdAt: phone.clock.withLock { $0 })
        _ = try await phone.outbox.flush()
        XCTAssertEqual(try pending(phone, one.id)?.undeliveredReason, .refused)
        XCTAssertEqual(try pending(phone, two.id)?.undeliveredReason, .noAnswer)

        try await phone.outbox.resendFrom(1)

        XCTAssertEqual(try pending(phone, one.id)?.undeliveredReason, .refused, "keeps its first reason")
        XCTAssertEqual(try pending(phone, two.id)?.undeliveredReason, .noAnswer, "keeps its first reason")
        XCTAssertEqual(try pending(phone, three.id)?.delivery, .sent, "resent, never listed")
        XCTAssertNil(try pending(phone, three.id)?.undeliveredReason)
        let controls = try await writtenControls(phone)
        XCTAssertEqual(controls.map(\.seq), [3])
    }

    func testAWithdrawalNeverOverlapsAFlush() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        _ = try await phone.outbox.flush()
        phone.advance(by: day + 1)
        let two = try await insert(phone, createdAt: phone.clock.withLock { $0 })
        let gate = await phone.inner.suspendNextSave()
        let outbox = phone.outbox
        let flush = Task { try await outbox.flush() }
        await gate.waitUntilReached()
        let sweep = Task { try await outbox.sweepSilentPending() }
        try await settle(phone)

        let during = await phone.recorder.events
        XCTAssertEqual(during, ["save", "saved", "save"], "no withdrawal while the flush runs")
        gate.open()
        _ = try await flush.value
        let swept = try await sweep.value

        XCTAssertEqual(swept, [one.id])
        let events = await phone.recorder.events
        XCTAssertEqual(events, ["save", "saved", "save", "saved", "delete"])
        XCTAssertEqual(try row(phone, two.id)?.delivery, .sent)
    }

    // MARK: - Retry and Dismiss

    func testRetryGoesToTheEndOfTheQueue() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone, params: ["note": .string("hi")])
        let two = try await insert(phone)
        await phone.inner.refuseNext(.permanent(code: "zoneNotFound"), count: 1)
        _ = try await phone.outbox.flush()

        do {
            _ = try await phone.outbox.retry(id: two.id)
            XCTFail("a row on its way cannot be retried")
        } catch ActionOutboxError.notRetryable {
            // expected
        }
        let retriedID = try await phone.outbox.retry(id: one.id)
        let retried = try XCTUnwrap(retriedID)
        _ = try await phone.outbox.flush()

        XCTAssertNotEqual(retried, one.id)
        XCTAssertNil(try pending(phone, one.id), "the old row goes")
        let fresh = try XCTUnwrap(pending(phone, retried))
        XCTAssertEqual(fresh.actionSeq, 3)
        XCTAssertEqual(fresh.action.kind, .targetDone)
        XCTAssertEqual(fresh.entityRecordName, "target-42")
        XCTAssertEqual(fresh.action.params, ["note": .string("hi")])
        XCTAssertEqual(fresh.delivery, .sent)
        let saves = await saves(phone)
        XCTAssertEqual(saves.last?.names, [try wire(phone, 3)])
    }

    /// Retry pressed on one row from two screens at once: one new action, the second press does nothing.
    func testTwoRetriesOfOneRowEnqueueOnce() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        await phone.inner.refuseNext(.permanent(code: "zoneNotFound"), count: 1)
        _ = try await phone.outbox.flush()

        async let first = phone.outbox.retry(id: one.id)
        async let second = phone.outbox.retry(id: one.id)
        let retried = try await [first, second].compactMap { $0 }

        XCTAssertEqual(retried.count, 1, "the second Retry is a no-op")
        XCTAssertNil(try pending(phone, one.id))
        XCTAssertEqual(try phone.store.pendingActions().map(\.id), retried)
    }

    func testDismissAllNeverResends() async throws {
        let phone = try await makePhone()
        try await insert(phone)
        try await insert(phone)
        await phone.inner.refuseNext(.permanent(code: "zoneNotFound"), count: 2)
        _ = try await phone.outbox.flush()

        let dismissed = try await phone.outbox.dismissAllUndelivered()
        XCTAssertEqual(dismissed, 2)
        try await phone.outbox.resendFrom(1)

        let saves = await saves(phone)
        XCTAssertEqual(saves.count, 3, "two refused writes, then the control alone")
        let controls = try await writtenControls(phone)
        XCTAssertEqual(controls.map(\.seq), [3])
    }

    // MARK: - Epoch keys (relay client Phase 3, Task 6)

    /// The phone's keybox moves to `epoch` (its keys join the stored ones, as the link flow's merge does).
    private func raiseEpoch(_ phone: Phone, to epoch: UInt32) throws {
        var link = try XCTUnwrap(try phone.keys.hubLink(hubID))
        link.epochs.append(EpochKeys(
            epoch: epoch, dataKey: Data(repeating: UInt8(epoch), count: 32), alertKey: Data(repeating: UInt8(epoch), count: 32)))
        try phone.keys.saveHubLink(link)
        XCTAssertEqual(try phone.secure.currentEpoch(), epoch)
    }

    private func epochAcks(_ phone: Phone) async throws -> [UInt32?] {
        try await writtenControls(phone).filter { $0.kind == .epochAck }.map(\.epoch)
    }

    private func envelopeHeader(_ data: Data) throws -> EnvelopeHeader {
        try Envelope.parse(data).header
    }

    func testEpochAckIsQueuedOncePerRaise() async throws {
        let phone = try await makePhone()
        try raiseEpoch(phone, to: 2)

        let first = try await phone.outbox.enqueueEpochAck(epoch: 2)
        let second = try await phone.outbox.enqueueEpochAck(epoch: 2)
        _ = try await phone.outbox.flush()

        XCTAssertTrue(first)
        XCTAssertFalse(second, "the same raise is acknowledged once")
        let acks = try await epochAcks(phone)
        XCTAssertEqual(acks, [2])
        let controls = try await writtenControls(phone)
        let control = try XCTUnwrap(controls.first)
        XCTAssertEqual(control.deviceID, device)
        XCTAssertEqual(control.hubID, hubID)
        XCTAssertTrue(try phone.store.queuedControls().isEmpty)

        try raiseEpoch(phone, to: 3)
        let third = try await phone.outbox.enqueueEpochAck(epoch: 3)
        _ = try await phone.outbox.flush()
        XCTAssertTrue(third)
        let both = try await epochAcks(phone)
        XCTAssertEqual(both.sorted { ($0 ?? 0) < ($1 ?? 0) }, [2, 3])
    }

    func testEpochAckNeverGoesDown() async throws {
        let phone = try await makePhone()
        try raiseEpoch(phone, to: 3)
        _ = try await phone.outbox.enqueueEpochAck(epoch: 3)
        _ = try await phone.outbox.flush()
        let lower = try await phone.outbox.enqueueEpochAck(epoch: 2)
        XCTAssertFalse(lower)
        XCTAssertTrue(try phone.store.queuedControls().isEmpty, "a lower epoch is never queued")

        // An unsent ack for a lower epoch is replaced by the newer one.
        await phone.inner.refuseNext(.unreachable, count: 1)
        try raiseEpoch(phone, to: 4)
        _ = try await phone.outbox.enqueueEpochAck(epoch: 4)
        await phone.outbox.drain()
        XCTAssertEqual(try phone.store.queuedControls().map(\.kind), [.epochAck], "the ack for 4 waits, refused")
        try raiseEpoch(phone, to: 5)
        _ = try await phone.outbox.enqueueEpochAck(epoch: 5)
        await phone.outbox.drain()
        _ = try await phone.outbox.flush()
        let acks = try await epochAcks(phone)
        XCTAssertEqual(acks.sorted { ($0 ?? 0) < ($1 ?? 0) }, [3, 5])
    }

    /// The epoch the ordered path turned on in is known to the hub: only a newer one is acknowledged, and the
    /// baseline never moves a recorded ack back.
    func testTheBaselineEpochIsNotAcknowledged() async throws {
        let phone = try await makePhone()
        try await phone.outbox.setEpochAckBaseline(1)
        let known = try await phone.outbox.enqueueEpochAck(epoch: 1)
        XCTAssertFalse(known)
        try raiseEpoch(phone, to: 2)
        let raised = try await phone.outbox.enqueueEpochAck(epoch: 2)
        XCTAssertTrue(raised)
        try await phone.outbox.setEpochAckBaseline(1)
        let again = try await phone.outbox.enqueueEpochAck(epoch: 2)
        XCTAssertFalse(again)
        await phone.outbox.drain()
        let acks = try await epochAcks(phone)
        XCTAssertEqual(acks, [2])
    }

    func testNoEpochAckToALegacyHub() async throws {
        let phone = try await makePhone(ordered: false)
        try raiseEpoch(phone, to: 2)
        let queued = try await phone.outbox.enqueueEpochAck(epoch: 2)
        _ = try await phone.outbox.flush()
        XCTAssertFalse(queued)
        XCTAssertTrue(try phone.store.queuedControls().isEmpty)
        let calls = await phone.recorder.calls
        XCTAssertTrue(calls.isEmpty)
    }

    /// Sim rule 14: `resend_from(1)` after the phone moved to epoch 2 reseals rows 1–2 (epoch 1) under epoch 2 and
    /// overwrites their records; row 3, already in epoch 2, is resent byte for byte.
    func testResendFromResealsOnlyOlderEpochRows() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        let two = try await insert(phone)
        _ = try await phone.outbox.flush()
        let oldOne = try XCTUnwrap(try row(phone, one.id))
        let oldTwo = try XCTUnwrap(try row(phone, two.id))
        try raiseEpoch(phone, to: 2)
        let three = try await insert(phone)
        _ = try await phone.outbox.flush()
        let oldThree = try XCTUnwrap(try row(phone, three.id))
        XCTAssertEqual([oldOne.epoch, oldTwo.epoch, oldThree.epoch], [1, 1, 2])

        try await phone.outbox.resendFrom(1)

        for (old, id) in [(oldOne, one.id), (oldTwo, two.id)] {
            let resealed = try XCTUnwrap(try row(phone, id))
            XCTAssertEqual(resealed.epoch, 2)
            XCTAssertNotEqual(resealed.envelope, old.envelope)
            XCTAssertEqual(try envelopeHeader(resealed.envelope).epoch, 2)
            XCTAssertEqual(resealed.wireName, old.wireName)
            XCTAssertEqual(resealed.delivery, .sent)
            let onWire = try await current(phone, old.wireName)
            XCTAssertEqual(onWire?.payload, resealed.envelope, "the record is overwritten")
        }
        let resent = try XCTUnwrap(try row(phone, three.id))
        XCTAssertEqual(resent.envelope, oldThree.envelope, "the current epoch's row keeps its bytes")
        let saves = await saves(phone)
        XCTAssertEqual(saves.dropFirst(3).map(\.names), [[oldOne.wireName], [oldTwo.wireName], [oldThree.wireName]])
        XCTAssertEqual(
            saves.dropFirst(3).map(\.expects),
            [[.seq(try XCTUnwrap(oldOne.recordSeq))], [.seq(try XCTUnwrap(oldTwo.recordSeq))],
             [.seq(try XCTUnwrap(oldThree.recordSeq))]],
            "each overwrite goes under the version of its last write")
    }

    func testAResealKeepsTheActionSeq() async throws {
        let phone = try await makePhone()
        let one = try await insert(phone)
        _ = try await phone.outbox.flush()
        let old = try XCTUnwrap(try row(phone, one.id))
        try raiseEpoch(phone, to: 2)

        try await phone.outbox.resendFrom(1)

        let resealed = try XCTUnwrap(try row(phone, one.id))
        XCTAssertEqual(resealed.actionSeq, old.actionSeq)
        XCTAssertGreaterThan(try envelopeHeader(resealed.envelope).seq, try envelopeHeader(old.envelope).seq, "a fresh envelope seq")
        let opened = try await phone.secure.changes(in: .relay, since: nil).changed
            .first { $0.kind == RelayRecordKind.action.rawValue }
        let action = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: try XCTUnwrap(opened).payload)
        XCTAssertEqual(action.id, one.id)
        XCTAssertEqual(action.actionSeq, one.seq)
        XCTAssertEqual(opened?.sealed?.epoch, 2)
    }

    /// A row of an older epoch whose stored envelope does not open cannot be resealed: listed as Not delivered.
    func testAnUnopenableOldRowIsNotDelivered() async throws {
        let phone = try await makePhone()
        let seq = try phone.store.nextActionSeq()
        let action = ActionRequestPayload(
            id: UUID().uuidString, kind: .targetDone, entityID: "42", createdAt: base, deviceID: device, hubID: hubID)
        let sealed = try await phone.secure.seal(try CloudRecordFactory.orderedRecord(
            for: action, actionSeq: seq, deviceID: TestE2E.deviceID, modifiedAt: base))
        var corrupt = sealed.payload
        corrupt[corrupt.count - 1] ^= 0xFF
        let broken = CloudRecord(
            recordName: sealed.recordName, zone: .relay, kind: sealed.kind, modifiedAt: base, payload: corrupt)
        XCTAssertTrue(try phone.store.insertOrderedAction(
            action, entityRecordName: "target-42", sealed: broken, epoch: 1, seq: seq))
        let good = try await insert(phone)
        try raiseEpoch(phone, to: 2)

        try await phone.outbox.resendFrom(1)

        // The overlay cannot open its envelope either, so the row is read from the outbox and the table.
        XCTAssertEqual(try row(phone, action.id)?.delivery, .undelivered)
        let reason = try await phone.store.reader.read { db in
            try String.fetchOne(
                db, sql: "SELECT undelivered_reason FROM pending_actions WHERE action_id = ?", arguments: [action.id])
        }
        XCTAssertEqual(reason, UndeliveredReason.refused.rawValue)
        let resealed = try XCTUnwrap(try row(phone, good.id))
        XCTAssertEqual(resealed.epoch, 2)
        XCTAssertEqual(resealed.delivery, .sent, "the rows after it go on")
        let skips = try await writtenControls(phone).filter { $0.kind == .skipTo }.map(\.seq)
        XCTAssertEqual(skips, [2], "the order skips the row listed as Not delivered")
    }
}

/// Records every call the phone's `SecureTransport` makes, then forwards it to the in-memory transport. `events`
/// marks a conditional save's start ("save") and return ("saved") and each conditional delete ("delete"), so a test
/// can see whether two operations overlapped.
actor RecordingConditionalTransport: ConditionalTransport {
    enum Call: Equatable {
        case plainSave([String])
        case plainDelete([String])
        case save(names: [String], expects: [WriteExpectation])
        case delete(names: [String], expects: [WriteExpectation])
    }

    struct Save: Equatable {
        let names: [String]
        let expects: [WriteExpectation]
    }

    let inner: InMemoryCloudTransport
    private(set) var calls: [Call] = []
    private(set) var events: [String] = []
    private var hooks: [Int: @Sendable () async throws -> Void] = [:]
    private var saveCount = 0

    init(inner: InMemoryCloudTransport) {
        self.inner = inner
    }

    var conditionalSaves: [Save] {
        calls.compactMap { call in
            if case let .save(names, expects) = call { return Save(names: names, expects: expects) }
            return nil
        }
    }

    var conditionalDeletes: [Save] {
        calls.compactMap { call in
            if case let .delete(names, expects) = call { return Save(names: names, expects: expects) }
            return nil
        }
    }

    /// Runs `hook` just before the conditional save with this zero-based index reaches the in-memory transport.
    func beforeSave(_ index: Int, _ hook: @escaping @Sendable () async throws -> Void) {
        hooks[index] = hook
    }

    func save(_ records: [CloudRecord]) async throws {
        calls.append(.plainSave(records.map(\.recordName)))
        try await inner.save(records)
    }

    func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        calls.append(.plainDelete(recordNames))
        try await inner.delete(recordNames: recordNames, in: zone)
    }

    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        try await inner.changes(in: zone, since: token)
    }

    func save(_ items: [ConditionalSave]) async throws -> [SaveOutcome] {
        let index = saveCount
        saveCount += 1
        calls.append(.save(names: items.map(\.record.recordName), expects: items.map(\.expect)))
        events.append("save")
        if let hook = hooks.removeValue(forKey: index) { try await hook() }
        let outcomes = try await inner.save(items)
        events.append("saved")
        return outcomes
    }

    func delete(_ items: [ConditionalDelete]) async throws -> [DeleteOutcome] {
        calls.append(.delete(names: items.map(\.recordName), expects: items.map(\.expect)))
        events.append("delete")
        return try await inner.delete(items)
    }
}

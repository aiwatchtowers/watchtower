import CryptoKit
import Foundation
import WatchtowerE2ETesting
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The phone's ordered path (relay client Phase 1, Task 8): a linked grant with `ordered_actions` turns it on for
/// good, every fetch flushes and sweeps the outbox, the hub's `resend_from` reaches an outbox that knows both ids,
/// and the four feature writers dismiss and retry through it.
@MainActor
final class OrderedActionsWiringTests: XCTestCase {
    private let deviceID = TestE2E.deviceID.uuidString
    private let hubID = TestE2E.hubID.uuidString

    private var device: LinkedDevice {
        LinkedDevice(
            deviceID: deviceID, name: "Colleague A's iPhone", model: "iPhone", appVersion: "1.0", scope: .private,
            userRecordName: "_owner-acme")
    }

    // MARK: - The grant turns the path on

    func testAGrantWithOrderedActionsTurnsTheOrderedPathOn() async throws {
        let transport = SwitchableTransport()
        let path = try makeReplicaPath()
        let first = try session(over: transport, path: path, closing: false)
        await first.waitForBoot()
        let before = try await first.outbox.orderedActions()
        XCTAssertFalse(before, "no grant yet")

        try await publishGrant(orderedActions: 1, over: transport)
        await fetch(first)
        let on = try await first.outbox.orderedActions()
        XCTAssertTrue(on)

        // A later grant without the flag never turns it off, nor does a restart.
        try await publishGrant(orderedActions: nil, over: transport, at: Date().addingTimeInterval(60))
        await fetch(first)
        await first.shutDown()
        first.closeDatabases()

        let second = try session(over: transport, path: path)
        await second.waitForBoot()
        await fetch(second)
        let still = try await second.outbox.orderedActions()
        XCTAssertTrue(still, "sticky per replica")
        try await second.boardWriter.setStatus(.done, on: try target(415))
        let row = try XCTUnwrap(try second.store.pendingActions().first)
        XCTAssertEqual(row.actionSeq, 1)
        XCTAssertNotNil(row.delivery)
    }

    func testAGrantWithoutTheFlagKeepsTodaysPath() async throws {
        let transport = SwitchableTransport()
        let env = try session(over: transport)
        await env.waitForBoot()
        try await publishGrant(orderedActions: nil, over: transport)
        await fetch(env)

        let on = try await env.outbox.orderedActions()
        XCTAssertFalse(on)
        try await env.boardWriter.setStatus(.done, on: try target(415))
        await fetch(env)
        let row = try XCTUnwrap(try env.store.pendingActions().first)
        XCTAssertNil(row.actionSeq)
        XCTAssertNil(row.delivery)
        let conditional = await transport.conditionalSaves
        XCTAssertTrue(conditional.isEmpty, "a legacy hub's flush never reaches the transport")
    }

    // MARK: - Fetches flush

    func testAFetchFlushesWhatWasQueued() async throws {
        let transport = SwitchableTransport()
        let env = try await orderedSession(over: transport)
        await transport.refuse(.unreachable)
        try await env.boardWriter.setStatus(.done, on: try target(415))
        await fetch(env)
        XCTAssertEqual(try env.store.pendingActions().first?.delivery, .queued)
        try await poll({ env.outboxBacklog.lastFlushStopped }, "the fetch's flush stopped on the refusal")
        try await poll({ env.outboxBacklog.queued == 1 }, "the backlog counts the queued action")

        await transport.refuse(nil)
        await fetch(env)
        XCTAssertEqual(try env.store.pendingActions().first?.delivery, .sent)
        try await poll({ env.outboxBacklog == .empty }, "nothing waits, and the last flush went through")
    }

    /// Every fetch sweeps (not only the boot's): a phone that stays up still withdraws an action the Mac never
    /// answered within 24 h.
    func testEveryFetchWithdrawsWhatTheMacNeverAnswered() async throws {
        let transport = SwitchableTransport()
        let clock = MutableClock()
        let env = try await orderedSession(over: transport, clock: clock)
        try await env.boardWriter.setStatus(.done, on: try target(415))
        await fetch(env)
        XCTAssertEqual(try env.store.pendingActions().first?.delivery, .sent)

        clock.advance(25 * 3600)
        await fetch(env)
        let row = try XCTUnwrap(try env.store.pendingActions().first)
        XCTAssertEqual(row.delivery, .undelivered)
        XCTAssertEqual(row.undeliveredReason, .noAnswer)
        try await poll({ env.outboxBacklog.undelivered == 1 }, "the backlog lists it")
    }

    /// The fetch starts the outbox's flush and sweep and returns without waiting for them: a save that hangs on
    /// the network never holds up a fetch's completion.
    func testAHungSaveDoesNotHoldUpAFetch() async throws {
        let transport = SwitchableTransport()
        let env = try await orderedSession(over: transport)
        await transport.holdNextSave()
        addTeardownBlock { await transport.releaseHeldSave() }
        try await env.boardWriter.setStatus(.done, on: try target(415))

        let fetched = expectation(description: "the fetch completed")
        Task {
            _ = await env.refresh(.pull)
            fetched.fulfill()
        }
        await fulfillment(of: [fetched], timeout: 5)
        XCTAssertEqual(try env.store.pendingActions().first?.delivery, .queued, "the save still hangs")

        await transport.releaseHeldSave()
        await env.outboxWork?.value
        XCTAssertEqual(try env.store.pendingActions().first?.delivery, .sent)
    }

    /// The flush an enqueue starts on its own reaches the backlog too, not only the session's.
    func testAFlushTheOutboxStartsItselfSetsLastFlushStopped() async throws {
        let transport = SwitchableTransport()
        let env = try await orderedSession(over: transport)
        await transport.refuse(.unreachable)
        try await env.boardWriter.setStatus(.done, on: try target(415))
        // Waits on the outbox's chain behind the enqueue's own flush; no session flush runs.
        _ = try await env.outbox.sweepSilentPending()
        try await poll({ env.outboxBacklog.lastFlushStopped }, "the enqueue's flush stopped on the refusal")
    }

    // MARK: - Dismiss and Retry through the outbox

    func testFeatureDismissAndRetryGoThroughTheOutbox() async throws {
        let transport = SwitchableTransport()
        let env = try await orderedSession(over: transport)
        let ask = try mirror(OwnerAsk.self, DemoSeed.JSON.ask(121, workbench: DemoSeed.acmeID, [
            "kind": "question", "payload": ["questions": [["id": "q", "question": "Which?", "options": [["label": "A"], ["label": "B"]]]]]
        ]))
        env.askDrafts.update(121) { $0.picks["q"] = AskQuestionPick(labels: ["A"]) }

        // Dismiss: each kind's undelivered row goes; a later `resend_from` writes only `skip_to`.
        try await sendAllFour(env, ask: ask, refusedBy: transport)
        let undelivered = try env.store.pendingActions()
        XCTAssertEqual(undelivered.map(\.delivery), Array(repeating: .undelivered, count: 4))
        for row in undelivered {
            switch row.action.kind {
            case .boardTargetStatus: try env.boardWriter.dismiss(try XCTUnwrap(BoardWriteRow(row, macOnline: true)))
            case .sessionStart: try env.sessionStarts.dismiss(row)
            case .sessionInput: try env.sessionInputs.dismiss(row)
            case .askAnswer: try env.askAnswerer.dismiss(row)
            default: XCTFail("unexpected kind \(row.action.kind.rawValue)")
            }
        }
        XCTAssertTrue(try env.store.pendingActions().isEmpty)

        let mark = await transport.conditionalSaves.count
        try await writeHubControl(.resendFrom, seq: 1, over: transport)
        await fetch(env)
        let written = await transport.conditionalSaves.dropFirst(mark)
        XCTAssertEqual(written.count, 1, "only the skip")
        let controls = try await phoneControls(in: transport)
        XCTAssertEqual(controls.map(\.kind), [.skipTo])
        XCTAssertEqual(controls.first?.seq, 5)
        XCTAssertEqual(controls.first?.hubID, hubID)
        XCTAssertEqual(controls.first?.deviceID, deviceID)

        // Retry: a new action at the end of the queue, the old row gone (session input has no Retry).
        try await sendAllFour(env, ask: ask, refusedBy: transport)
        let failed = try env.store.pendingActions()
        let lastSeq = try XCTUnwrap(failed.compactMap(\.actionSeq).max())
        for row in failed {
            switch row.action.kind {
            case .boardTargetStatus: try await env.boardWriter.setStatus(.done, on: try target(415))
            case .sessionStart: _ = try await env.sessionStarts.retry(row)
            case .askAnswer: _ = try await env.askAnswerer.send(ask)
            default: continue
            }
            let rows = try env.store.pendingActions()
            XCTAssertFalse(rows.contains { $0.id == row.id }, "\(row.action.kind.rawValue): the old row goes")
            let retried = try XCTUnwrap(rows.first { $0.action.kind == row.action.kind && $0.id != row.id })
            XCTAssertGreaterThan(try XCTUnwrap(retried.actionSeq), lastSeq, "at the end of the queue")
        }
    }

    // MARK: - Removal

    func testARemovalCountsUnsentOrderedActionsAsNotSent() async throws {
        let transport = SwitchableTransport()
        let env = try await orderedSession(over: transport)
        // Not delivered first: a permanent refusal passes over every queued row.
        await transport.refuse(.permanent(code: "zone_gone"))
        _ = try await env.sessionInputs.send(sessionID: 7, text: "hello")
        _ = try await env.outbox.flush()
        await transport.refuse(nil)
        try await env.boardWriter.setStatus(.done, on: try target(415))
        _ = try await env.outbox.flush()
        await transport.refuse(.unreachable)
        try await env.boardWriter.setPriority(.low, on: try target(415))
        _ = try await env.outbox.flush()

        XCTAssertEqual(
            try env.store.pendingActions().compactMap(\.delivery).sorted { $0.rawValue < $1.rawValue },
            [.queued, .sent, .undelivered])
        XCTAssertEqual(AppRoot.pendingActionCount(env), 2, "queued and sent are not sent; Not delivered is listed")
    }

    // MARK: - Helpers

    private func session(
        over transport: SwitchableTransport, path: String? = nil, clock: MutableClock = MutableClock(), closing: Bool = true
    ) throws -> HubSession {
        let sleeper = TickSleeper()
        let env = try HubSession(
            transport: transport,
            replicaPath: try path ?? makeReplicaPath(),
            transportKind: .cloudKit,
            hubID: hubID,
            linkedDevice: device,
            keys: try TestPhone.keys(),
            defaults: try makeDefaults(),
            recordingsDirectory: try makeRecordingsDirectory(),
            now: { clock.now },
            sleep: { try await sleeper.sleep($0) }
        )
        if closing {
            closeAtTeardown(env)
        }
        return env
    }

    /// A booted session whose grant turned the ordered path on.
    private func orderedSession(over transport: SwitchableTransport, clock: MutableClock = MutableClock()) async throws -> HubSession {
        let env = try session(over: transport, clock: clock)
        await env.waitForBoot()
        try await publishGrant(orderedActions: 1, over: transport)
        await fetch(env)
        let on = try await env.outbox.orderedActions()
        XCTAssertTrue(on)
        return env
    }

    private func publishGrant(orderedActions: Int?, over transport: SwitchableTransport, at: Date = Date()) async throws {
        let grant = DeviceGrant(
            deviceID: deviceID, hubID: hubID, name: "Colleague A's iPhone", scope: .private, linked: true,
            typingAllowed: true, startSessionsAllowed: true, mayStartSessions: true, orderedActions: orderedActions)
        try await TestPhone.hub(over: transport.inner).save([try TestPhone.grantRecord(grant, modifiedAt: at)])
    }

    /// One fetch, then the outbox work it started (flush, sweep).
    private func fetch(_ env: HubSession) async {
        _ = await env.refresh(.pull)
        await env.outboxWork?.value
    }

    private func target(_ id: Int64) throws -> WorkbenchTarget {
        try XCTUnwrap(try demoSnapshot(now: Date()).targets.first { $0.id == id })
    }

    /// One action of each writer's kind, listed as Not delivered (the zone refused them for good).
    private func sendAllFour(_ env: HubSession, ask: OwnerAsk, refusedBy transport: SwitchableTransport) async throws {
        await transport.refuse(.permanent(code: "zone_gone"))
        try await env.boardWriter.setStatus(.done, on: try target(415))
        let start = SessionStartParams(workbenchID: DemoSeed.acmeID, mode: .new, planFirst: false, bringForward: false)
        _ = try await env.sessionStarts.start(targetID: 415, params: start)
        _ = try await env.sessionInputs.send(sessionID: 7, text: "hello")
        _ = try await env.askAnswerer.send(ask)
        _ = try await env.outbox.flush()
        await transport.refuse(nil)
    }

    /// The hub's control to this phone, sealed as the Go hub's `sealControl` does.
    private func writeHubControl(_ kind: ControlKind, seq: UInt64, over transport: SwitchableTransport) async throws {
        let control = ControlPayload(id: UUID().uuidString, kind: kind, deviceID: deviceID, hubID: hubID, seq: seq)
        let hub = TestPhone.hub(over: transport.inner)
        let keys = TestE2E.hub(firstSeq: TestPhone.nextSeqBlock())
        let wire = try hub.wireName(plain: control.recordName, zone: .relay)
        let frame = InnerFrame(
            kind: RelayRecordKind.control.rawValue, id: control.recordName,
            payload: try RelayCoder.makeEncoder().encode(control))
        let epoch = try keys.currentEpoch()
        let envelope = try EnvelopeSealer.sealSymmetric(
            frame, envelopeClass: .relayToPhone, key: try keys.relayKey(.hubToPhone, deviceID: TestE2E.deviceID, epoch: epoch),
            hubID: TestE2E.hubID, senderID: TestE2E.hubID, epoch: epoch, seq: try keys.nextSeq(),
            context: EnvelopeContext(zone: .relay, wireName: wire), signer: nil)
        try await transport.inner.save([CloudRecord(
            recordName: wire, zone: .relay, kind: WireKind.envelope, modifiedAt: Date(), payload: envelope)])
    }

    /// The phone's own controls in the mailbox, opened as the phone opens its own records.
    private func phoneControls(in transport: SwitchableTransport) async throws -> [ControlPayload] {
        let opened = try await TestPhone.transport(over: transport.inner).changes(in: .relay, since: nil).changed
        return try opened
            .filter { $0.kind == RelayRecordKind.control.rawValue }
            .map { try RelayCoder.makeDecoder().decode(ControlPayload.self, from: $0.payload) }
    }
}

/// The in-memory transport whose conditional saves are refused with `refusal` while one is set; records every
/// conditional save it was asked for.
private actor SwitchableTransport: ConditionalTransport {
    let inner = InMemoryCloudTransport()
    private var refusal: TransportRefusal?
    /// The next conditional save waits here until released.
    private var holdsNextSave = false
    private var heldSave: CheckedContinuation<Void, Never>?
    private(set) var conditionalSaves: [ConditionalSave] = []

    func refuse(_ refusal: TransportRefusal?) {
        self.refusal = refusal
    }

    func holdNextSave() {
        holdsNextSave = true
    }

    func releaseHeldSave() {
        holdsNextSave = false
        heldSave?.resume()
        heldSave = nil
    }

    func save(_ records: [CloudRecord]) async throws {
        try await inner.save(records)
    }

    func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        try await inner.delete(recordNames: recordNames, in: zone)
    }

    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        try await inner.changes(in: zone, since: token)
    }

    func save(_ items: [ConditionalSave]) async throws -> [SaveOutcome] {
        conditionalSaves += items
        if holdsNextSave {
            holdsNextSave = false
            await withCheckedContinuation { heldSave = $0 }
        }
        if let refusal {
            return items.map { _ in .refused(refusal) }
        }
        return try await inner.save(items)
    }

    func delete(_ items: [ConditionalDelete]) async throws -> [DeleteOutcome] {
        try await inner.delete(items)
    }
}

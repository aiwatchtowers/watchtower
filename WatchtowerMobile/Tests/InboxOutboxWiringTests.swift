import Foundation
import WatchtowerE2ETesting
import WatchtowerInterface
import WatchtowerKit
@testable import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// An Inbox press waiting in the outbox (mobile Inbox spec §9 "The phone is killed with actions queued"): the
/// outbox is persistent, so a relaunch sends the queued `inbox_act` as it was.
@MainActor
final class InboxOutboxWiringTests: XCTestCase {
    private let deviceID = TestE2E.deviceID.uuidString
    private let hubID = TestE2E.hubID.uuidString

    func testQueuedInboxActSurvivesAnAppKill() async throws {
        let transport = InboxSwitchableTransport()
        let path = try makeReplicaPath()
        let first = try session(over: transport, path: path, closing: false)
        await first.waitForBoot()
        try await publishGrant(over: transport)
        await fetch(first)
        let ordered = try await first.outbox.orderedActions()
        XCTAssertTrue(ordered)
        await first.epochAckWork?.value
        await first.outbox.drain()

        // The hub cannot be reached: the press waits in the outbox, busy on the phone.
        await transport.refuse(.unreachable)
        let request = ActRequest(
            requestID: "req-kill", target: DemoSeed.Inbox.waitingForMe, verb: .ref,
            params: ActParams(refKind: .inboxItem, refID: 301, refVerb: .resolve)
        )
        let center = first.inbox
        let press = Task { await center.press { _ in request } }
        try await poll({ (try? first.store.pendingActions().contains { $0.action.kind == .inboxAct }) == true }, "the inbox_act queued")
        await fetch(first)
        let queued = try XCTUnwrap(try first.store.pendingActions().first { $0.action.kind == .inboxAct })
        XCTAssertEqual(queued.delivery, .queued)
        XCTAssertEqual(first.inbox.rowState("inbox_item:301"), .busy(request))

        // The kill: the session goes without the press ever answering.
        press.cancel()
        await first.shutDown()
        first.closeDatabases()

        // The relaunch on the same replica: the row is there as written, and the first fetch sends it.
        let second = try session(over: transport, path: path)
        await second.waitForBoot()
        let kept = try XCTUnwrap(try second.store.pendingActions().first { $0.id == queued.id })
        XCTAssertEqual(kept.action.kind, .inboxAct)
        XCTAssertEqual(kept.action.params, try HubTransport.wireParams(request), "the same request, so the hub's ledger keeps it to once")
        await transport.refuse(nil)
        await fetch(second)
        XCTAssertEqual(try second.store.pendingActions().first { $0.id == queued.id }?.delivery, .sent)
        let saves = await transport.conditionalSaves
        XCTAssertFalse(saves.isEmpty, "the relaunch's flush reached the hub")
    }

    /// A press the outbox never delivered has one identity: the row's Retry and the Not delivered list's Retry are
    /// the same outbox retry of the same action (same request_id), so pressing both sends one action (review I1).
    func testAnUndeliveredPressRetriesAsOneAction() async throws {
        let transport = InboxSwitchableTransport()
        let env = try session(over: transport, path: try makeReplicaPath())
        await env.waitForBoot()
        try await publishGrant(over: transport)
        await fetch(env)
        await env.epochAckWork?.value
        await env.outbox.drain()

        await transport.refuse(.permanent(code: "zone_gone"))
        let request = ActRequest(
            requestID: "req-once", target: DemoSeed.Inbox.roundup, verb: .runNow, params: ActParams(contentHash: "hash-o205"))
        let press = Task { await env.inbox.press { _ in request } }
        try await poll({ (try? env.store.pendingActions().contains { $0.action.kind == .inboxAct }) == true }, "queued")
        _ = try await env.outbox.flush()
        try await poll({ InboxActSettlement.isUndelivered(env.inbox.actions.first ?? Self.none) }, "listed as Not delivered")
        await press.value
        guard case let .refused(sentence, .outbox(actionID, _))? = env.inbox.rowState(DemoSeed.Inbox.roundup) else {
            return XCTFail("the row offers the outbox's Retry: \(String(describing: env.inbox.rowState(DemoSeed.Inbox.roundup)))")
        }
        XCTAssertEqual(sentence, InboxPhoneText.notDelivered(hub: ""))

        await transport.refuse(nil)
        async let fromRow: Void = env.inbox.retry(.outbox(actionID: actionID, request))
        async let fromList: Void = { try? await env.retry(actionID: actionID) }()
        _ = await (fromRow, fromList)
        try await poll({ (try? env.store.pendingActions().filter { $0.action.kind == .inboxAct }.count) == 1 }, "one action left")
        let rows = try env.store.pendingActions().filter { $0.action.kind == .inboxAct }
        XCTAssertEqual(rows.count, 1, "both Retries sent one action")
        XCTAssertNotEqual(rows[0].id, actionID, "the retried action replaced the undelivered one")
        XCTAssertEqual(rows[0].action.params["request_id"], .string("req-once"), "under the same request_id")
        await env.inbox.retry(.outbox(actionID: actionID, request))
        XCTAssertEqual(try env.store.pendingActions().filter { $0.action.kind == .inboxAct }.count, 1, "a late Retry is a no-op")
    }

    private static var none: PendingAction {
        PendingAction(
            id: "", action: ActionRequestPayload(id: "", kind: .inboxAct, entityID: nil, params: [:], createdAt: Date(), deviceID: nil),
            entityRecordName: nil, createdAt: Date(), state: .pending, errorMessage: nil, reason: nil, result: nil, echoStatus: nil,
            actionSeq: nil, epoch: nil, delivery: nil, undeliveredReason: nil)
    }

    // MARK: - The session

    private var device: LinkedDevice {
        LinkedDevice(
            deviceID: deviceID, name: "Colleague A's iPhone", model: "iPhone", appVersion: "1.0", scope: .private, userRecordName: "_owner-acme")
    }

    private func session(over transport: InboxSwitchableTransport, path: String, closing: Bool = true) throws -> HubSession {
        let sleeper = TickSleeper()
        let clock = MutableClock()
        let env = try HubSession(
            transport: transport,
            replicaPath: path,
            backend: .live,
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

    /// A linked grant with the ordered path on (relay client Phase 1).
    private func publishGrant(over transport: InboxSwitchableTransport) async throws {
        let grant = DeviceGrant(
            deviceID: deviceID, hubID: hubID, name: "Colleague A's iPhone", scope: .private, linked: true,
            typingAllowed: true, startSessionsAllowed: true, mayStartSessions: true, orderedActions: 1)
        try await TestPhone.hub(over: transport.inner).save([try TestPhone.grantRecord(grant, modifiedAt: Date())])
    }

    /// One fetch, then the outbox work it started (flush, sweep).
    private func fetch(_ env: HubSession) async {
        _ = await env.refresh(.pull)
        await env.outboxWork?.value
    }
}

/// A conditional transport that can refuse every conditional save (the hub out of reach).
private actor InboxSwitchableTransport: ConditionalTransport {
    let inner = InMemoryCloudTransport()
    private var refusal: TransportRefusal?
    private(set) var conditionalSaves: [ConditionalSave] = []

    func refuse(_ refusal: TransportRefusal?) {
        self.refusal = refusal
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
        if let refusal {
            return items.map { _ in .refused(refusal) }
        }
        conditionalSaves += items
        return try await inner.save(items)
    }

    func delete(_ items: [ConditionalDelete]) async throws -> [DeleteOutcome] {
        try await inner.delete(items)
    }
}

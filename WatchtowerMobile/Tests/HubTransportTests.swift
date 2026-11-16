import Foundation
import WatchtowerInterface
import WatchtowerKit
@testable import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The phone's tower transport (mobile Inbox spec §7): `inbox.feed` assembled from the hub's records, `inbox.act`
/// through the outbox as `inbox_act`, and the outbox's states on `TowerClient`'s.
@MainActor
final class HubTransportTests: XCTestCase {
    private let now = Date()

    func testFeedAssembledFromRecords() throws {
        var feed = DemoSeed.Inbox.feed(now: now)
        feed.more = [FolderMore(folderID: DemoSeed.Inbox.releaseID, count: 42)]
        var records = try FakeInboxHub.records(feed)
        // The replica holds records in no order of the feed's, and a record this build cannot read is skipped.
        records.folders.reverse()
        records.cards.shuffle()
        records.cards.append(Data(#"{"id": 7}"#.utf8))

        let assembled = try HubTransport.assemble(records)

        XCTAssertEqual(assembled.folders.map(\.id), feed.folders.sorted { ($0.position, $0.id) < ($1.position, $1.id) }.map(\.id))
        XCTAssertEqual(Set(assembled.cards.map(\.id)), Set(feed.cards.map(\.id)))
        XCTAssertEqual(assembled.more, [FolderMore(folderID: DemoSeed.Inbox.releaseID, count: 42)])
        // inboxfeed.Limit's order: Needs approval's open proposals, then the pinned card, then newest first.
        let approvals = assembled.cards.prefix { $0.folderID == DemoSeed.Inbox.approvalsID }
        XCTAssertEqual(approvals.count, 4, "the open proposals and the reminder lead")
        let rest = assembled.cards.dropFirst(4)
        XCTAssertEqual(rest.first?.id, DemoSeed.Inbox.waitingForMe, "then the pinned card")
        XCTAssertEqual(Array(rest.dropFirst().map(\.stamp)), rest.dropFirst().map(\.stamp).sorted(by: >), "then newest first")

        let root = InboxRootModel(feed: assembled, platform: .phone)
        XCTAssertEqual(root.badge, 5, "Needs approval's 2 and Waiting for me's 3")
        XCTAssertEqual(
            InboxFolderModel(feed: assembled, folderID: DemoSeed.Inbox.releaseID, platform: .phone, hidden: InboxHiddenRows(), now: now)
                .olderLine,
            InboxText.olderCards(42)
        )
    }

    func testActEnqueuesInboxActWithTheRequestJSON() async throws {
        let store = try TestPhone.replica()
        let outbox = ActionOutbox(transport: try TestPhone.transport(), store: store, deviceID: DemoSeed.device.deviceID)
        let transport = HubTransport(store: store, outbox: outbox)
        await outbox.setAppliedObserver { action in transport.settle(actionID: action.id, .applied(result: nil)) }
        let request = ActRequest(
            requestID: "req-1", target: DemoSeed.Inbox.waitingForMe, verb: .ref,
            params: ActParams(refKind: .inboxItem, refID: 301, refVerb: .resolve)
        )
        let call = Request(v: 1, id: "c1", command: TowerCommand.inboxAct.rawValue, params: try RawJSON(data: try JSONEncoder().encode(request)))

        let answer = Task { try await transport.call(call) }
        try await poll({ (try? store.pendingActions().isEmpty) == false }, "the inbox_act queued")
        let row = try XCTUnwrap(try store.pendingActions().first)
        XCTAssertEqual(row.action.kind, .inboxAct)
        XCTAssertNil(row.entityRecordName, "inbox_act carries no entity")
        XCTAssertEqual(row.action.params, try HubTransport.wireParams(request))
        XCTAssertEqual(row.action.params["request_id"], .string("req-1"))
        XCTAssertEqual(row.action.params["verb"], .string("ref"))

        var echo = row.action
        echo.status = .applied
        try await outbox.applyEcho(echo)
        let response = try await answer.value
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.id, "c1")
    }

    /// Queued → busy; applied → ok; refused by the hub → the hub's sentence; not delivered → the phone's sentence;
    /// outcome_unknown → unknown.
    func testOutboxStatesMapToTowerStates() async throws {
        let hub = FakeInboxHub(feed: DemoSeed.Inbox.feed(now: now))
        let client = TowerClient(transport: hub.transport, clock: ContinuousClock(), restartDaemon: nil, startDaemon: nil)
        let cases: [(InboxActSettlement, TowerActOutcome<RawJSON>)] = [
            (.applied(result: Data(#"{"already":true}"#.utf8)), .ok(try RawJSON(data: Data(#"{"already":true}"#.utf8)))),
            (.refused(code: .changed, sentence: "This card changed — look again."), .refused("This card changed — look again.")),
            (.notDelivered(sentence: InboxPhoneText.notDelivered(hub: "Acme Mac")), .refused(InboxPhoneText.notDelivered(hub: "Acme Mac"))),
            (.unknown, .unknown)
        ]
        for (offset, (settlement, expected)) in cases.enumerated() {
            let key = "press-\(offset)"
            let press = Task {
                await client.act(.inboxAct, key: key) { requestID -> ActRequest in
                    ActRequest(requestID: requestID, target: "o205", verb: .done, params: ActParams(contentHash: "hash-o205"))
                } as TowerActOutcome<RawJSON>
            }
            try await poll({ hub.requests.count == offset + 1 }, "press \(offset) queued")
            let busy = await client.actionState(key: key)
            XCTAssertEqual(busy, .busy, "queued is busy")
            hub.transport.settle(actionID: "act-\(offset + 1)", settlement)
            let outcome = await press.value
            XCTAssertEqual(Self.shape(outcome), Self.shape(expected), "\(settlement)")
        }

        // The replica's failed rows read as their settlements.
        func row(_ reason: ActionReason?, message: String?, delivery: Delivery?) -> PendingAction {
            PendingAction(
                id: "x", action: ActionRequestPayload(id: "x", kind: .inboxAct, entityID: nil, params: [:], createdAt: now, deviceID: "phone"),
                entityRecordName: nil, createdAt: now, state: .failed, errorMessage: message, reason: reason, result: nil, echoStatus: nil,
                actionSeq: nil, epoch: nil, delivery: delivery, undeliveredReason: nil
            )
        }
        XCTAssertEqual(InboxActSettlement.of(row(.outcomeUnknown, message: "restarted", delivery: nil), hubName: "Acme Mac"), .unknown)
        XCTAssertEqual(
            InboxActSettlement.of(row(.conflict, message: "This card changed — look again.", delivery: nil), hubName: "Acme Mac"),
            .refused(code: .changed, sentence: "This card changed — look again.")
        )
        XCTAssertEqual(
            InboxActSettlement.of(row(nil, message: nil, delivery: .undelivered), hubName: "Acme Mac"),
            .notDelivered(sentence: InboxPhoneText.notDelivered(hub: "Acme Mac"))
        )
        XCTAssertEqual(
            InboxActSettlement.of(row(.notSupported, message: "", delivery: nil), hubName: "Acme Mac"),
            .refused(code: .unsupported, sentence: InboxPhoneText.refusedFallback)
        )
    }

    /// An outcome without its decoded result (the client re-reads it).
    private static func shape(_ outcome: TowerActOutcome<RawJSON>) -> String {
        switch outcome {
        case .ok: "ok"
        case let .refused(sentence): "refused: \(sentence)"
        case .unknown: "unknown"
        case let .failed(failure): "failed: \(failure.sentence)"
        }
    }

    /// The hub stopped mid-way: the press reads Didn't confirm, the client re-reads the feed, and nothing is sent
    /// again — neither by the client nor by a second tap.
    func testUnknownIsNeverResent() async throws {
        let hub = FakeInboxHub(feed: DemoSeed.Inbox.feed(now: now))
        let center = try await startedInboxCenter(hub)
        let card = try XCTUnwrap(center.feed?.cards.first { $0.id == DemoSeed.Inbox.roundup })
        let model = InboxCardModel(card: card, platform: .phone, grants: .all, blocksReadable: true, now: now)
        let key = InboxPressKey.card(card, .runNow)
        let readsBefore = center.reads

        let press = Task { await center.press(key, on: card.id, hides: false) { model.request(.runNow, requestID: $0) } }
        try await poll({ hub.requests.count == 1 }, "Run Now queued")
        hub.transport.settle(actionID: "act-1", .unknown)
        await press.value

        XCTAssertEqual(center.state(key), .unknown)
        try await poll({ center.reads > readsBefore }, "the client re-read the feed")
        await center.press(key, on: card.id, hides: false) { model.request(.runNow, requestID: $0) }
        XCTAssertEqual(hub.requests.count, 1, "a second tap sends nothing")
        XCTAssertEqual(hub.requests.first?.verb, .runNow)
        XCTAssertEqual(hub.requests.first?.params.contentHash, card.contentHash)
    }
}

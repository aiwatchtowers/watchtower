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
        XCTAssertEqual(assembled.cards.map(\.id), feed.cards.map(\.id), "each folder's card_ids: the feed's own order")
        XCTAssertEqual(assembled.more, [FolderMore(folderID: DemoSeed.Inbox.releaseID, count: 42)])
        let approvals = { (cards: [InboxCard]) in cards.filter { $0.folderID == DemoSeed.Inbox.approvalsID }.map(\.id) }
        XCTAssertEqual(approvals(assembled.cards), approvals(feed.cards), "Needs approval lists as the feed does")

        // An older hub's folders list no card ids: inboxfeed.Limit's order — Needs approval's open entries, the
        // pinned card, then newest first.
        let unpositioned = InboxRecords(folders: try records.folders.map { payload in
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            object["card_ids"] = nil
            return try JSONSerialization.data(withJSONObject: object)
        }, cards: Array(records.cards.dropLast()))
        let fallback = try HubTransport.assemble(unpositioned).cards
        XCTAssertEqual(fallback.prefix { $0.folderID == DemoSeed.Inbox.approvalsID }.count, 4)
        XCTAssertEqual(fallback.dropFirst(4).first?.id, DemoSeed.Inbox.waitingForMe)
        XCTAssertEqual(Array(fallback.dropFirst(5).map(\.stamp)), fallback.dropFirst(5).map(\.stamp).sorted(by: >))

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
            (.refused(code: .changed, sentence: "This card changed — look again."),
             .refused(Refusal(code: .changed, sentence: "This card changed — look again."))),
            (.notDelivered(sentence: InboxPhoneText.notDelivered(hub: "Acme Mac")),
             .refused(Refusal(code: .unsupported, sentence: InboxPhoneText.notDelivered(hub: "Acme Mac")))),
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
        func row(_ reason: ActionReason?, message: String?, delivery: Delivery?, result: [String: JSONValue]? = nil) -> PendingAction {
            PendingAction(
                id: "x", action: ActionRequestPayload(id: "x", kind: .inboxAct, entityID: nil, params: [:], createdAt: now, deviceID: "phone"),
                entityRecordName: nil, createdAt: now, state: .failed, errorMessage: message, reason: reason, result: result, echoStatus: nil,
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
        // The tower's own code rides in the echo's result: the phone keeps it as the Mac does.
        for code in ["args_changed", "reply_waiting", "not_permitted"] {
            XCTAssertEqual(
                InboxActSettlement.of(row(.conflict, message: "Go's sentence.", delivery: nil, result: ["code": .string(code)]),
                                      hubName: "Acme Mac"),
                .refused(code: RefusalCode(rawValue: code), sentence: "Go's sentence."),
                code
            )
        }
    }

    /// An outcome without its decoded result (the client re-reads it).
    private static func shape(_ outcome: TowerActOutcome<RawJSON>) -> String {
        switch outcome {
        case .ok: "ok"
        case let .refused(refusal): "refused: \(refusal.sentence)"
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
        let readsBefore = center.reads

        let press = Task { await center.press { model.request(.runNow, requestID: $0) } }
        try await poll({ hub.requests.count == 1 }, "Run Now queued")
        hub.transport.settle(actionID: "act-1", .unknown)
        await press.value

        XCTAssertEqual(center.rowState(card.id), .unknown)
        try await poll({ center.reads > readsBefore }, "the client re-read the feed")
        await center.press { model.request(.runNow, requestID: $0) }
        XCTAssertEqual(hub.requests.count, 1, "a second tap sends nothing")
        XCTAssertEqual(hub.requests.first?.verb, .runNow)
        XCTAssertEqual(hub.requests.first?.params.contentHash, card.contentHash)
    }

    /// A replica read or an outbox write that fails is a refusal with the phone's sentence — never "the tower is
    /// down", which would reconnect and re-send forever (review I4).
    func testLocalFailuresAreRefusalsNotADownTower() async throws {
        let hub = FakeInboxHub(feed: DemoSeed.Inbox.feed(now: now))
        hub.fail(true)
        let read = try await hub.transport.call(Request(v: 1, id: "r", command: TowerCommand.inboxFeed.rawValue))
        XCTAssertEqual(read.status, .refused)
        XCTAssertEqual(read.refusal?.sentence, InboxPhoneText.localFailure)
        let request = ActRequest(requestID: "q", target: "o205", verb: .done, params: ActParams(contentHash: "hash-o205"))
        let act = try await hub.transport.call(
            Request(v: 1, id: "a", command: TowerCommand.inboxAct.rawValue, params: try RawJSON(data: try JSONEncoder().encode(request))))
        XCTAssertEqual(act.status, .refused)
        XCTAssertEqual(act.refusal?.sentence, InboxPhoneText.localFailure)
        XCTAssertTrue(hub.requests.isEmpty)

        // Through the client: the press ends refused with Retry, once; nothing loops.
        hub.fail(false)
        let center = try await startedInboxCenter(hub)
        hub.fail(true)
        let card = try XCTUnwrap(center.feed?.cards.first { $0.id == DemoSeed.Inbox.roundup })
        let model = InboxCardModel(card: card, platform: .phone, grants: .all, blocksReadable: true, now: now)
        await center.press { model.request(.done, requestID: $0) }
        guard case let .refused(sentence, .resend(again, nil))? = center.rowState(card.id) else {
            return XCTFail("a local failure shows refused with Retry: \(String(describing: center.rowState(card.id)))")
        }
        XCTAssertEqual(sentence, InboxPhoneText.localFailure)
        XCTAssertEqual(again.verb, .done)
        hub.fail(false)
        // The hub answers the re-sent press only when settled here: the Retry waits for that answer.
        let retry = Task { await center.retry(.resend(again, dismiss: nil)) }
        try await poll({ hub.requests.count == 1 }, "Retry sends it once the phone can")
        hub.transport.settle(actionID: "act-1", .applied(result: nil))
        await retry.value
        XCTAssertNil(center.rowState(card.id), "ok clears the refusal")
    }

    /// A call the client abandoned (its write limit) and re-sent with the same request_id waits for the action it
    /// already queued and gets its settlement, never a second action.
    func testAnAbandonedCallReSentWaitsForTheSameAction() async throws {
        let hub = FakeInboxHub(feed: DemoSeed.Inbox.feed(now: now))
        let request = ActRequest(requestID: "same", target: "o205", verb: .runNow, params: ActParams(contentHash: "hash-o205"))
        let call = Request(v: 1, id: "c", command: TowerCommand.inboxAct.rawValue, params: try RawJSON(data: try JSONEncoder().encode(request)))
        let first = Task { try await hub.transport.call(call) }
        try await poll({ hub.requests.count == 1 }, "queued")
        first.cancel()
        _ = try? await first.value
        hub.transport.settle(actionID: "act-1", .refused(code: .changed, sentence: "This card changed — look again."))

        let again = try await hub.transport.call(call)
        XCTAssertEqual(again.status, .refused)
        XCTAssertEqual(again.refusal?.sentence, "This card changed — look again.")
        XCTAssertEqual(hub.requests.count, 1, "the same action, not a second one")
    }
}

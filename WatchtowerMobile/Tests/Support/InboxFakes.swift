import Foundation
import WatchtowerInterface
@testable import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// A hub behind `HubTransport` for the Inbox tests: the records it holds (as published), and every `inbox_act` the
/// phone enqueued, each answered `act-1`, `act-2`… as its action id.
final class FakeInboxHub: @unchecked Sendable {
    private let lock = NSLock()
    private var held = InboxRecords()
    private var sent: [ActRequest] = []
    private var failing = false

    /// A local failure: the replica cannot be read and nothing can be queued.
    func fail(_ on: Bool) {
        lock.withLock { failing = on }
    }

    init(feed: Feed? = nil) {
        if let feed { publish(feed) }
    }

    /// Replaces the records with `feed`'s (each folder with its `more`).
    func publish(_ feed: Feed) {
        let records = (try? Self.records(feed)) ?? InboxRecords()
        lock.withLock { held = records }
    }

    var requests: [ActRequest] { lock.withLock { sent } }

    lazy var transport = HubTransport(
        records: { [weak self] in
            guard let self else { return InboxRecords() }
            return try lock.withLock {
                if self.failing { throw CocoaError(.fileReadCorruptFile) }
                return self.held
            }
        },
        enqueue: { [weak self] request in
            guard let self else { throw CancellationError() }
            return try lock.withLock {
                if self.failing { throw CocoaError(.fileWriteUnknown) }
                self.sent.append(request)
                return "act-\(self.sent.count)"
            }
        }
    )

    /// The hub's records of `feed`, as `InboxSource` writes them: each folder with its `more` and its cards' ids in
    /// the feed's order (`card_ids`), the cards order-free.
    static func records(_ feed: Feed) throws -> InboxRecords {
        let encoder = JSONEncoder()
        let more = Dictionary((feed.more ?? []).map { ($0.folderID, $0.count) }) { first, _ in first }
        let folders = try feed.folders.map { folder -> Data in
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try encoder.encode(folder)) as? [String: Any])
            if let count = more[folder.id] { object["more"] = count }
            object["card_ids"] = feed.cards.filter { $0.folderID == folder.id }.map(\.id)
            return try JSONSerialization.data(withJSONObject: object)
        }
        let cards = try feed.cards.map { try encoder.encode($0) }
        return InboxRecords(folders: folders, cards: cards)
    }
}

@MainActor
extension XCTestCase {
    /// A started center over `hub`, its first feed read.
    func startedInboxCenter(_ hub: FakeInboxHub) async throws -> InboxCenter {
        let center = InboxCenter(transport: hub.transport)
        center.start()
        addTeardownBlock { @MainActor in center.stop() }
        try await poll({ center.feed != nil }, "the first feed read")
        return center
    }
}

extension FakeInboxHub {
    /// A failed `inbox_act` row as the replica holds it after a relaunch or a give-up: `request`, refused with
    /// `reason` and `message`, or Not delivered.
    static func failedRow(
        _ request: ActRequest, id: String, reason: ActionReason?, message: String?, undelivered: Bool = false, at: Date = Date()
    ) throws -> PendingAction {
        PendingAction(
            id: id,
            action: ActionRequestPayload(
                id: id, kind: .inboxAct, entityID: nil, params: try HubTransport.wireParams(request), createdAt: at, deviceID: "phone"),
            entityRecordName: nil, createdAt: at, state: .failed, errorMessage: message, reason: reason, result: nil, echoStatus: nil,
            actionSeq: undelivered ? 1 : nil, epoch: undelivered ? 1 : nil, delivery: undelivered ? .undelivered : nil,
            undeliveredReason: undelivered ? .refused : nil
        )
    }
}

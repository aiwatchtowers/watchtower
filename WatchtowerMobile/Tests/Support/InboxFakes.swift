import Foundation
import WatchtowerInterface
import XCTest
@testable import WatchtowerMobile

/// A hub behind `HubTransport` for the Inbox tests: the records it holds (as published), and every `inbox_act` the
/// phone enqueued, each answered `act-1`, `act-2`… as its action id.
final class FakeInboxHub: @unchecked Sendable {
    private let lock = NSLock()
    private var held = InboxRecords()
    private var sent: [ActRequest] = []

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
        records: { [weak self] in self?.lock.withLock { self?.held } ?? InboxRecords() },
        enqueue: { [weak self] request in
            guard let self else { throw CancellationError() }
            return lock.withLock {
                self.sent.append(request)
                return "act-\(self.sent.count)"
            }
        }
    )

    /// The hub's records of `feed`, as `InboxSource` writes them (each card with its feed position).
    static func records(_ feed: Feed) throws -> InboxRecords {
        let encoder = JSONEncoder()
        let more = Dictionary((feed.more ?? []).map { ($0.folderID, $0.count) }) { first, _ in first }
        let folders = try feed.folders.map { folder -> Data in
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try encoder.encode(folder)) as? [String: Any])
            if let count = more[folder.id] { object["more"] = count }
            return try JSONSerialization.data(withJSONObject: object)
        }
        let cards = try feed.cards.enumerated().map { position, card -> Data in
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try encoder.encode(card)) as? [String: Any])
            object["position"] = position
            return try JSONSerialization.data(withJSONObject: object)
        }
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

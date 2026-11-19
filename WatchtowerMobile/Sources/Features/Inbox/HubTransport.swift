import Foundation
import os
import WatchtowerInterface
import WatchtowerKit
import WatchtowerSync

/// The Inbox records the replica holds: every `inbox_folder` and `inbox_card` payload, as the hub published them.
struct InboxRecords: Sendable {
    var folders: [Data] = []
    var cards: [Data] = []
}

/// Where one `inbox_act` left the outbox (mobile Inbox spec §7): the hub applied it (its result), the hub refused it
/// (its code and sentence), the outbox could not deliver it (Not delivered), or the hub stopped mid-way
/// (`outcome_unknown`).
enum InboxActSettlement: Equatable, Sendable {
    case applied(result: Data?)
    case refused(code: RefusalCode, sentence: String)
    case notDelivered(sentence: String)
    case unknown

    /// The outbox could not deliver it (listed under Not delivered): one predicate for the row's state and the
    /// outbox line.
    static func isUndelivered(_ row: PendingAction) -> Bool {
        row.state == .failed && (row.delivery == .undelivered || row.undeliveredReason != nil)
    }

    /// A failed `inbox_act` row as the replica holds it; nil while it still waits.
    static func of(_ row: PendingAction, hubName: String) -> Self? {
        guard row.state == .failed else { return nil }
        if row.reason == .outcomeUnknown { return .unknown }
        if isUndelivered(row) {
            return .notDelivered(sentence: InboxPhoneText.notDelivered(hub: hubName))
        }
        let sentence = row.errorMessage.flatMap { $0.isEmpty ? nil : $0 } ?? InboxPhoneText.refusedFallback
        return .refused(code: code(row.reason, result: row.result), sentence: sentence)
    }

    /// The tower's own refusal code: go-hub `inbox_act` puts it in the echo's result (`{"code": …}`), so the phone
    /// carries the same `Refusal` as the Mac (`args_changed` and `reply_waiting` stay apart). An echo without one —
    /// a grant refusal before the tower ran, an older hub — falls back to its reason.
    static func code(_ reason: ActionReason?, result: [String: JSONValue]?) -> RefusalCode {
        if case let .string(raw)? = result?["code"], !raw.isEmpty { return RefusalCode(rawValue: raw) }
        return code(reason)
    }

    /// The hub's echo reason back to the tower's code (go-hub `inbox_act`: `not_found`; `changed`, `args_changed` and
    /// `reply_waiting` → `conflict`; `not_permitted` and `unsupported` → `not_supported`).
    static func code(_ reason: ActionReason?) -> RefusalCode {
        switch reason {
        case .notFound?: .notFound
        case .conflict?, .changed?: .changed
        case .deviceNotAllowed?: .notPermitted
        default: .unsupported
        }
    }
}

/// The phone's `TowerTransport` (mobile Inbox spec §7): the Inbox screens talk to `TowerClient` as the Mac's do, and
/// this answers them from the hub's replica.
///
/// - `tower.hello` answers this build's interface version: the hub's own version shows as its `inbox` capability.
/// - `inbox.feed` is assembled from the `inbox_folder` and `inbox_card` records (`assemble`).
/// - `inbox.act` goes through the outbox as `inbox_act` (its params are the request) and answers when the action
///   settles: applied → `ok` with the act's result, refused → `refused` with the hub's sentence, not delivered →
///   `refused` with the phone's sentence, `outcome_unknown` → `unknown`. While queued the call waits, so the client
///   shows the press busy and the outbox lines show it queued. A call cancelled meanwhile (the client's answer limit)
///   leaves the action in the outbox; a re-send of the same request_id waits for that same action, never a second one.
/// - `inbox.watch` yields `changed` on every publish of the two kinds (`published()`).
final class HubTransport: TowerTransport, @unchecked Sendable {
    typealias Enqueue = @Sendable (_ request: ActRequest) async throws -> String

    private let records: @Sendable () throws -> InboxRecords
    private let enqueue: Enqueue
    private let lock = NSLock()
    /// The press waiting for each action id.
    private var waiters: [String: CheckedContinuation<InboxActSettlement, Never>] = [:]
    /// Settlements that came before their waiter (an echo racing the enqueue's return).
    private var early: [String: InboxActSettlement] = [:]
    /// The action each request_id went out as, until it settles.
    private var actions: [String: String] = [:]
    /// Enqueues on their way (their action ids are not known yet).
    private var enqueuing = 0
    private var watchers: [UUID: AsyncThrowingStream<ChangedEvent, Error>.Continuation] = [:]
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "HubTransport")

    init(records: @escaping @Sendable () throws -> InboxRecords, enqueue: @escaping Enqueue) {
        self.records = records
        self.enqueue = enqueue
    }

    /// The live phone: the replica's records, the hub's outbox.
    convenience init(store: ReplicaStore, outbox: ActionOutbox) {
        self.init(
            records: { try Self.read(store) },
            enqueue: { request in
                try await outbox.enqueue(kind: .inboxAct, entityRecordName: nil, params: try Self.wireParams(request))
            }
        )
    }

    // MARK: - TowerTransport

    func call(_ request: Request) async throws -> Response {
        switch TowerCommand(rawValue: request.command) {
        case .towerHello?:
            let hello = HelloResponse(interfaceVersion: InterfaceVersion.current, build: "hub", syncPaused: false, noSync: false)
            return try Self.ok(request.id, hello)
        case .inboxFeed?:
            do {
                return try Self.ok(request.id, try Self.assemble(try records()))
            } catch {
                // A local failure is a refusal with Retry, never "the tower is down": that would reconnect and
                // re-send forever.
                Self.logger.error("inbox feed not read: \(String(describing: type(of: error)), privacy: .public)")
                return Self.refusal(request.id, .unsupported, InboxPhoneText.localFailure)
            }
        case .inboxAct?:
            return try await act(request)
        default:
            return Self.refusal(request.id, .unsupported, InboxPhoneText.notOnThePhone)
        }
    }

    func watch(_ request: Request) -> AsyncThrowingStream<ChangedEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ChangedEvent, Error>.makeStream(bufferingPolicy: .bufferingNewest(16))
        guard TowerCommand(rawValue: request.command) == .inboxWatch else {
            continuation.finish(throwing: TowerTransportError.refused(Refusal(code: .unsupported, sentence: InboxPhoneText.notOnThePhone)))
            return stream
        }
        let id = UUID()
        lock.withLock { watchers[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.watchers.removeValue(forKey: id) } }
        return stream
    }

    // MARK: - The replica's side

    /// The hub published `inbox_folder` or `inbox_card`: every open watch hears `changed`.
    func published() {
        let event = ChangedEvent(id: "", event: "changed", tables: [SliceKind.inboxFolder.rawValue, SliceKind.inboxCard.rawValue])
        lock.withLock { Array(watchers.values) }.forEach { $0.yield(event) }
    }

    /// An `inbox_act` settled (its applied echo, or its failed row).
    func settle(actionID: String, _ settlement: InboxActSettlement) {
        let waiter: CheckedContinuation<InboxActSettlement, Never>? = lock.withLock {
            guard let waiter = waiters.removeValue(forKey: actionID) else {
                // Kept only for a press about to wait (an echo racing the enqueue's return, or a re-send of an
                // abandoned call); one nobody waits for shows from the replica, not from here.
                if enqueuing > 0 || actions.values.contains(actionID) { early[actionID] = settlement }
                return nil
            }
            return waiter
        }
        waiter?.resume(returning: settlement)
    }

    // MARK: - inbox.act

    private func act(_ request: Request) async throws -> Response {
        guard let data = request.params?.data, let act = try? JSONDecoder().decode(ActRequest.self, from: data) else {
            return Self.refusal(request.id, .unsupported, InboxText.couldNotSend)
        }
        let actionID: String
        if let queued = lock.withLock({ actions[act.requestID] }) {
            actionID = queued
        } else {
            lock.withLock { enqueuing += 1 }
            do {
                let id = try await enqueue(act)
                lock.withLock {
                    enqueuing -= 1
                    actions[act.requestID] = id
                }
                actionID = id
            } catch {
                lock.withLock { enqueuing -= 1 }
                Self.logger.error("inbox_act not queued: \(String(describing: type(of: error)), privacy: .public)")
                return Self.refusal(request.id, .unsupported, InboxPhoneText.localFailure)
            }
        }
        let settlement = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready: InboxActSettlement? = lock.withLock {
                    if let done = early.removeValue(forKey: actionID) { return done }
                    // Cancelled before it waited: onCancel found no waiter to end.
                    if Task.isCancelled { return .notDelivered(sentence: "") }
                    waiters[actionID] = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            // The client gave up (its answer limit): the action stays queued, and the next send of the same
            // request_id waits for it again.
            let waiter = lock.withLock { waiters.removeValue(forKey: actionID) }
            waiter?.resume(returning: .notDelivered(sentence: ""))
        }
        try Task.checkCancellation()
        lock.withLock { _ = actions.removeValue(forKey: act.requestID) }
        return Self.response(request.id, settlement)
    }

    static func response(_ id: String, _ settlement: InboxActSettlement) -> Response {
        switch settlement {
        case let .applied(result):
            let raw = (try? RawJSON(data: result ?? Data("{}".utf8))) ?? (try? RawJSON(data: Data("{}".utf8)))
            return Response(id: id, status: .ok, result: raw)
        case let .refused(code, sentence):
            return refusal(id, code, sentence)
        case let .notDelivered(sentence):
            return refusal(id, .unsupported, sentence)
        case .unknown:
            return Response(id: id, status: .unknownStatus)
        }
    }

    // MARK: - The feed

    /// The records back into the generated `Feed`: folders by position (`more` read off each folder record), cards
    /// in the feed's own order from each folder record's `card_ids` (the replica keeps no publish order). A card no
    /// folder lists (an older hub's records) sorts after them in `inboxfeed.Limit`'s order — Needs approval's open
    /// entries, the pinned cards, then newest first. Records that do not decode are left out.
    static func assemble(_ records: InboxRecords) throws -> Feed {
        let decoder = JSONDecoder()
        var folders: [(folder: Folder, cardIDs: [String])] = []
        var more: [FolderMore] = []
        for payload in records.folders {
            guard let folder = try? decoder.decode(Folder.self, from: payload) else {
                logger.warning("an inbox folder record does not decode")
                continue
            }
            let extra = try? decoder.decode(RecordExtra.self, from: payload)
            folders.append((folder, extra?.cardIDs ?? []))
            if let count = extra?.more, count > 0 {
                more.append(FolderMore(folderID: folder.id, count: count))
            }
        }
        folders.sort { ($0.folder.position, $0.folder.id) < ($1.folder.position, $1.folder.id) }
        let order = folders.map(\.cardIDs)
        let approvals = folders.first { $0.folder.kind == .approvals }?.folder.id
        var positions: [String: Int] = [:]
        for id in order.flatMap({ $0 }) where positions[id] == nil {
            positions[id] = positions.count
        }
        let cards = records.cards.compactMap { payload -> (card: InboxCard, position: Int?)? in
            guard let card = try? decoder.decode(InboxCard.self, from: payload) else {
                logger.warning("an inbox card record does not decode")
                return nil
            }
            return (card, positions[card.id])
        }
        .sorted { lhs, rhs in
            switch (lhs.position, rhs.position) {
            case let (a?, b?) where a != b: return a < b
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            let (a, b) = (tier(lhs.card, approvals), tier(rhs.card, approvals))
            if a != b { return a < b }
            if lhs.card.stamp != rhs.card.stamp { return lhs.card.stamp > rhs.card.stamp }
            return lhs.card.id < rhs.card.id
        }
        .map(\.card)
        more.sort { $0.folderID < $1.folderID }
        return Feed(v: 1, builtAt: "", folders: folders.map(\.folder), cards: cards, more: more.isEmpty ? nil : more)
    }

    /// Needs approval (0), the pinned cards (1), the rest (2); inside Needs approval, an open proposal before a
    /// settled one. Only for cards no folder record lists.
    private static func tier(_ card: InboxCard, _ approvals: Int64?) -> Int {
        if card.folderID == approvals {
            let open = card.approval.map { $0.status == "pending" || $0.status == "failed" } ?? true
            return open ? 0 : 1
        }
        return card.pinned ? 2 : 3
    }

    /// What a folder record carries beside the generated `Folder`: `more` and `card_ids`.
    private struct RecordExtra: Decodable {
        let more: Int?
        let cardIDs: [String]?

        enum CodingKeys: String, CodingKey {
            case more
            case cardIDs = "card_ids"
        }
    }

    /// Every Inbox record of `store`.
    static func read(_ store: ReplicaStore) throws -> InboxRecords {
        try store.reader.read { db in
            InboxRecords(folders: try store.payloads(of: .inboxFolder, from: db), cards: try store.payloads(of: .inboxCard, from: db))
        }
    }

    /// The `inbox_act` params: the generated request as JSON.
    static func wireParams(_ request: ActRequest) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: try JSONEncoder().encode(request))
    }

    private static func ok(_ id: String, _ value: some Encodable) throws -> Response {
        Response(id: id, status: .ok, result: try RawJSON(data: try JSONEncoder().encode(value)))
    }

    private static func refusal(_ id: String, _ code: RefusalCode, _ sentence: String) -> Response {
        Response(id: id, status: .refused, refusal: Refusal(code: code, sentence: sentence))
    }
}

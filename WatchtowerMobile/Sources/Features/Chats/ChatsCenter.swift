import Foundation
import GRDB
import Observation
import os
import WatchtowerKit
import WatchtowerSync

/// A chat screen pushed on the Chats tab's stack (iPhone chat spec §6.2): one conversation, or a new chat (`new`).
/// `messageID` is a search hit's message, which the conversation screen scrolls to.
struct ChatRoute: Hashable {
    /// 0 is a new chat, as on the hub (`chat_feed_request` id 0 names no conversation).
    let id: Int64
    var messageID: Int64?

    static let new = Self(id: 0)

    var isNew: Bool { id == 0 }
}

/// Sends one chat action through the hub's outbox. Chat actions carry no entity (spec §4.5).
struct ChatSender {
    let send: @MainActor (ActionKind, [String: JSONValue]) async throws -> Void

    @MainActor
    func callAsFunction<P: ActionParams>(_ params: P) async throws {
        try await send(P.actionKind, try params.wireParams())
    }

    @MainActor
    static func through(_ outbox: ActionOutbox) -> Self {
        Self { kind, params in
            try await outbox.enqueue(kind: kind, entityRecordName: nil, params: params)
        }
    }
}

/// What the Chats tab reads from this hub's replica in one snapshot: the `chat_list` record, the `chat_search`
/// records by the query they answer, and the newest chat action the hub refused for want of the `chat` grant.
struct ChatsSnapshot: Equatable {
    var list: ChatList?
    var searches: [String: ChatSearch] = [:]
    /// The refusal's message while the newest chat action this phone sent was refused with `device_not_allowed`.
    var refusal: String?
    /// The chats whose `chat_manage delete` the hub refused, by when the newest refused one was queued.
    var refusedDeletes: [Int64: Date] = [:]

    nonisolated static func read(from db: Database, store: ReplicaStore, cache: ReplicaDecodeCache) throws -> Self {
        let versions = try store.kindVersions([.chatList, .chatSearch], from: db)
        var snapshot = Self()
        snapshot.list = try cache.value(ChatList.recordName, version: versions[.chatList] ?? 0) {
            guard let payload = try store.payload(forRecordName: ChatList.recordName, from: db) else { return nil }
            return try? ChatList.decode(payload: payload)
        }
        snapshot.searches = try cache.value(SliceKind.chatSearch.rawValue, version: versions[.chatSearch] ?? 0) {
            let decoded = try store.payloads(of: .chatSearch, from: db).compactMap { try? ChatSearch.decode(payload: $0) }
            return Dictionary(decoded.map { ($0.query, $0) }) { _, newer in newer }
        }
        let pending = try store.pendingActions(from: db)
        snapshot.refusal = Self.refusal(in: pending)
        snapshot.refusedDeletes = Self.refusedDeletes(in: pending)
        return snapshot
    }

    /// Every failed `chat_manage delete` by its chat, the newest queue time kept.
    nonisolated static func refusedDeletes(in pending: [PendingAction]) -> [Int64: Date] {
        var refused: [Int64: Date] = [:]
        for row in pending where row.state == .failed && row.action.kind == .chatManage {
            guard let params = try? ChatManageParams(wireParams: row.action.params), params.op == .delete else { continue }
            refused[params.conversationID] = max(refused[params.conversationID] ?? .distantPast, row.createdAt)
        }
        return refused
    }

    /// The newest chat action's refusal for the grant; nil when that action went or waits.
    nonisolated static func refusal(in pending: [PendingAction]) -> String? {
        guard let newest = pending.filter({ ChatsCenter.chatKinds.contains($0.action.kind) }).max(by: { $0.createdAt < $1.createdAt }),
              newest.state == .failed, newest.reason == .deviceNotAllowed
        else { return nil }
        return newest.errorMessage ?? ""
    }
}

/// One hub's chats on the phone (iPhone chat spec §6): the replica's chat records under one observation, the
/// sender every chat screen sends through, the list's search and its row actions. Owned by the `HubSession`, so a
/// pending delete or a running search survive the tab switch.
@MainActor
@Observable
final class ChatsCenter {
    nonisolated static let chatKinds: Set<ActionKind> = [
        .chatNew, .chatTurn, .chatCancel, .chatFeedRequest, .chatPage, .chatSearch, .chatRead, .chatBranchSelect,
        .chatManage, .chatActionAnswer
    ]

    private(set) var snapshot = ChatsSnapshot()
    @ObservationIgnored let sender: ChatSender
    let search: ChatSearchModel
    let rowActions: ChatRowActions
    @ObservationIgnored let decodeCache = ReplicaDecodeCache()
    @ObservationIgnored private var cancellable: ResilientObservation?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "ChatsCenter")

    /// `sleep` times the search's debounce and patience and the delete's Undo window; tests step it by hand.
    init(sender: ChatSender, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sender = sender
        search = ChatSearchModel(sender: sender, sleep: sleep)
        rowActions = ChatRowActions(sender: sender, sleep: sleep)
    }

    /// Observes the replica's chat records for the session's lifetime.
    func start(store: ReplicaStore, gate: ReplicaObservationGate? = nil) {
        guard cancellable == nil else { return }
        let cache = decodeCache
        cancellable = ResilientObservation(
            name: "chats",
            reader: store.reader,
            gate: gate,
            observation: {
                ValueObservation.tracking(regions: [ReplicaStore.kindVersionsRegion, ReplicaStore.pendingActionsRegion]) { db in
                    try ChatsSnapshot.read(from: db, store: store, cache: cache)
                }
                .removeDuplicates()
            },
            onChange: { [weak self] value in self?.apply(value) }
        )
    }

    /// A snapshot as the observation delivers it (the screenshot tour sets its own).
    func apply(_ value: ChatsSnapshot) {
        guard value != snapshot else { return }
        if let list = value.list, list != snapshot.list {
            rowActions.prune(keeping: Set(list.conversations.map(\.id)))
        }
        if value.refusedDeletes != snapshot.refusedDeletes {
            rowActions.restoreRefused(value.refusedDeletes)
        }
        snapshot = value
    }

    /// The error state's Retry (mockup 1h): asks the hub to publish `chat_list` again, `chat_feed_request` with
    /// conversation 0. False when the request could not be queued.
    @discardableResult
    func retryList() async -> Bool {
        do {
            try await sender(ChatFeedRequestParams(conversationID: 0, purpose: .prefetch))
            return true
        } catch {
            Self.logger.warning("chat list retry not queued: \(String(describing: type(of: error)), privacy: .public)")
            return false
        }
    }
}

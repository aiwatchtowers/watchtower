import ChatWire
import Foundation
import Observation

/// The conversation list (unified chat spec §6.1): the list store fed by the client, search, pin, rename and delete
/// with Undo. A delete hides the row for `undoWindow` and is sent when it ends; Undo sends nothing; a refused delete
/// brings the row back.
@MainActor
@Observable
public final class ChatListModel {
    public static let undoWindow: Duration = .seconds(5)
    public static let deletedLine = "Chat deleted"
    public static let undoLabel = "Undo"
    public static let deleteFailedLine = "Couldn't delete the chat."
    public static let actionFailedLine = "Couldn't change the chat."

    public let client: any ChatClient
    public let store = ChatListStore()
    /// The chat whose delete waits for the Undo window to end.
    public private(set) var pendingDelete: Int64?
    public private(set) var notice: String?
    public private(set) var searchResult: ChatSearch?

    @ObservationIgnored private let clock: any ChatUIClock
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored var pendingCommit: Task<Void, Never>?

    public init(client: any ChatClient, clock: any ChatUIClock = ContinuousChatUIClock()) {
        self.client = client
        self.clock = clock
    }

    /// The conversations shown: the list without the one being deleted.
    public var conversations: [ChatList.Conversation] {
        (store.list?.conversations ?? []).filter { $0.id != pendingDelete }
    }

    public var isStale: Bool { store.isStale }

    public func start() {
        guard listTask == nil else { return }
        let updates = client.list()
        listTask = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                self.store.apply(update)
            }
        }
    }

    public func stop() {
        listTask?.cancel()
        listTask = nil
    }

    /// Hides the row and sends the delete when the Undo window ends; a second delete sends the first one now.
    public func delete(_ id: Int64) {
        if let previous = pendingDelete {
            pendingCommit?.cancel()
            Task { await commit(previous) }
        }
        pendingDelete = id
        notice = nil
        pendingCommit = Task { [clock] in
            do { try await clock.sleep(for: Self.undoWindow) } catch { return }
            guard !Task.isCancelled else { return }
            await self.commit(id)
        }
    }

    /// Brings the row back; nothing is sent.
    public func undo() {
        pendingCommit?.cancel()
        pendingCommit = nil
        pendingDelete = nil
    }

    private func commit(_ id: Int64) async {
        let echo = try? await client.send(.manage(conversationID: id, op: .delete, title: nil, projectID: nil))
        if pendingDelete == id { pendingDelete = nil }
        if case .applied? = echo { return }
        notice = Self.deleteFailedLine
    }

    public func pin(_ id: Int64) async {
        let pinned = store.list?.conversations.first { $0.id == id }?.pinned ?? false
        await manage(id, op: pinned ? .unpin : .pin)
    }

    public func rename(_ id: Int64, _ title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await manage(id, op: .rename, title: trimmed)
    }

    public func move(_ id: Int64, toProject projectID: Int64?) async {
        await manage(id, op: .move, projectID: projectID)
    }

    /// Full-text search over the chats; an empty query clears it.
    public func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResult = nil
            return
        }
        if case .applied(.search(let result))? = try? await client.send(.search(query: trimmed)) {
            searchResult = result
        }
    }

    private func manage(_ id: Int64, op: ChatManageOp, title: String? = nil, projectID: Int64? = nil) async {
        let echo = try? await client.send(.manage(conversationID: id, op: op, title: title, projectID: projectID))
        if case .applied? = echo {
            notice = nil
        } else {
            notice = Self.actionFailedLine
        }
    }
}

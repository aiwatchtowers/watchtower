import Foundation
import GRDB
import WatchtowerCore

@MainActor
@Observable
final class ChatHistoryViewModel {
    var conversations: [ChatConversation] = []
    var selectedConversationID: Int64?
    var searchText = ""
    var lastError: String?
    /// Injectable for tests; section boundaries are computed against it.
    @ObservationIgnored var now: () -> Date = Date.init

    private let dbManager: DatabaseManager
    /// Every write of this view model, in order (board #670).
    @ObservationIgnored private let writes = SerialWrites()
    /// One pending pin write per chat (board #670).
    let pendingWrites = PendingWrites()
    /// `chat_files/` root for post-delete cleanup; nil without an active
    /// workspace, matching `ChatAttachmentStore.defaultRootDir()`.
    private let attachmentsRoot: URL?

    init(dbManager: DatabaseManager, attachmentsRoot: URL? = ChatAttachmentStore.defaultRootDir()) {
        self.dbManager = dbManager
        self.attachmentsRoot = attachmentsRoot
    }

    /// The history column. A chat with neither a message nor an unsent file
    /// (the Chat landing's draft, an untouched project chat) is listed only
    /// while it is the one selected, i.e. on screen.
    var sections: [ChatHistorySection] {
        let listed = filteredConversations.filter {
            $0.activeLeafMessageID != nil || $0.hasAttachments || $0.id == selectedConversationID
        }
        return ChatHistoryGrouping.group(listed, now: now(), calendar: .current)
    }

    /// ↑/↓ in the history column: the listed chat `offset` rows from the
    /// selected one, in the order shown; with none selected (the landing, a
    /// project page) ↓ picks the first and ↑ the last. It stops at either
    /// end. Returns whether the selection moved.
    @discardableResult
    func selectAdjacent(by offset: Int) -> Bool {
        let ids = sections.flatMap(\.conversations).map(\.id)
        guard !ids.isEmpty, offset != 0 else { return false }
        let target: Int
        if let current = selectedConversationID, let index = ids.firstIndex(of: current) {
            target = min(max(index + offset, 0), ids.count - 1)
        } else {
            target = offset > 0 ? 0 : ids.count - 1
        }
        guard ids[target] != selectedConversationID else { return false }
        selectedConversationID = ids[target]
        return true
    }

    func rename(_ id: Int64, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await mutate { db in try ChatConversationQueries.rename(db, id: id, title: String(trimmed.prefix(120))) }
    }

    /// A second press while the pin is written does nothing (board #670).
    func togglePin(_ id: Int64) async {
        await pendingWrites.run("pin:\(id)") {
            let pinned = conversations.first { $0.id == id }?.pinned ?? false
            await mutate { db in try ChatConversationQueries.pin(db, id: id, pinned: !pinned) }
        }
    }

    /// The selection moves on only once the chat is archived.
    /// - Returns: whether it was archived (`lastError` says why not).
    @discardableResult
    func archive(_ id: Int64) async -> Bool {
        guard await mutate({ db in try ChatConversationQueries.archive(db, id: id) }) else { return false }
        if selectedConversationID == id { selectedConversationID = conversations.first?.id }
        return true
    }

    /// ⌘K. A read failure is reported, not shown as "no results".
    func search(_ query: String) -> [ChatSearchHit] {
        do {
            return try dbManager.dbPool.read { db in try ChatSearchQueries.search(db, query: query) }
        } catch {
            lastError = "Search failed: \(error.localizedDescription)"
            return []
        }
    }

    @discardableResult
    private func mutate(_ write: @escaping @Sendable (Database) throws -> Void) async -> Bool {
        do {
            try await chained { db in try write(db) }
            lastError = nil
            reloadSynchronously()
            return true
        } catch {
            // A chat deleted elsewhere leaves the list instead of lingering.
            if error is RowNotFoundError { reloadSynchronously() }
            lastError = error.localizedDescription
            return false
        }
    }

    var filteredConversations: [ChatConversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return conversations }
        return conversations.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var selectedConversation: ChatConversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    func load(completion: (() -> Void)? = nil) {
        Task.detached { [dbManager] in
            let items = try? await dbManager.dbPool.read { db in
                try ChatConversationQueries.fetchStandalone(db)
            }
            await MainActor.run {
                self.conversations = items ?? []
                completion?()
            }
        }
    }

    func createConversation() async -> ChatConversation? {
        do {
            let conv = try await chained { db in
                try ChatConversationQueries.create(db)
            }
            conversations.insert(conv, at: 0)
            selectedConversationID = conv.id
            return conv
        } catch {
            return nil
        }
    }

    func deleteConversation(_ id: Int64) async {
        do {
            try await chained { db in
                try ChatConversationQueries.delete(db, id: id)
            }
            // Rows are already gone by FK cascade; only the files remain.
            if let attachmentsRoot {
                ChatAttachmentStore.removeFiles(for: .conversation(id), rootDir: attachmentsRoot)
            }
            conversations.removeAll { $0.id == id }
            if selectedConversationID == id {
                selectedConversationID = conversations.first?.id
            }
        } catch {
            // silently ignore
        }
    }

    func updateTitle(_ id: Int64, title: String) async {
        let trimmed = String(title.prefix(80))
        do {
            try await chained { db in
                try ChatConversationQueries.updateTitle(db, id: id, title: trimmed)
            }
            reloadSynchronously()
        } catch {
            // silently ignore
        }
    }

    func updateSessionID(_ id: Int64, sessionID: String) async {
        do {
            try await chained { db in
                try ChatConversationQueries.updateSessionID(db, id: id, sessionID: sessionID)
            }
            reloadSynchronously()
        } catch {
            // silently ignore
        }
    }

    func touch(_ id: Int64) async {
        do {
            try await chained { db in
                try ChatConversationQueries.touch(db, id: id)
            }
            reloadSynchronously()
        } catch {
            // silently ignore
        }
    }

    private func reloadSynchronously() {
        let items = try? dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchStandalone(db)
        }
        conversations = items ?? []
    }

    /// A database write in this view model's chain (board #670): it starts
    /// only once every write asked for before it finished.
    private func chained<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await writes.runThrowing { try await self.dbManager.dbPool.write(body) }
    }
}

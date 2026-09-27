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
    /// `chat_files/` root for post-delete cleanup; nil without an active
    /// workspace, matching `ChatAttachmentStore.defaultRootDir()`.
    private let attachmentsRoot: URL?

    init(dbManager: DatabaseManager, attachmentsRoot: URL? = ChatAttachmentStore.defaultRootDir()) {
        self.dbManager = dbManager
        self.attachmentsRoot = attachmentsRoot
    }

    var sections: [ChatHistorySection] {
        ChatHistoryGrouping.group(filteredConversations, now: now(), calendar: .current)
    }

    func rename(_ id: Int64, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate { db in try ChatConversationQueries.rename(db, id: id, title: String(trimmed.prefix(120))) }
    }

    func togglePin(_ id: Int64) {
        let pinned = conversations.first { $0.id == id }?.pinned ?? false
        mutate { db in try ChatConversationQueries.pin(db, id: id, pinned: !pinned) }
    }

    func archive(_ id: Int64) {
        mutate { db in try ChatConversationQueries.archive(db, id: id) }
        if selectedConversationID == id { selectedConversationID = conversations.first?.id }
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

    private func mutate(_ write: (Database) throws -> Void) {
        do {
            try dbManager.dbPool.write { db in try write(db) }
            lastError = nil
            reloadSynchronously()
        } catch {
            lastError = error.localizedDescription
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

    func createConversation() -> ChatConversation? {
        do {
            let conv = try dbManager.dbPool.write { db in
                try ChatConversationQueries.create(db)
            }
            conversations.insert(conv, at: 0)
            selectedConversationID = conv.id
            return conv
        } catch {
            return nil
        }
    }

    func deleteConversation(_ id: Int64) {
        do {
            try dbManager.dbPool.write { db in
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

    func updateTitle(_ id: Int64, title: String) {
        let trimmed = String(title.prefix(80))
        do {
            try dbManager.dbPool.write { db in
                try ChatConversationQueries.updateTitle(db, id: id, title: trimmed)
            }
            reloadSynchronously()
        } catch {
            // silently ignore
        }
    }

    func updateSessionID(_ id: Int64, sessionID: String) {
        do {
            try dbManager.dbPool.write { db in
                try ChatConversationQueries.updateSessionID(db, id: id, sessionID: sessionID)
            }
            reloadSynchronously()
        } catch {
            // silently ignore
        }
    }

    func touch(_ id: Int64) {
        do {
            try dbManager.dbPool.write { db in
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
}

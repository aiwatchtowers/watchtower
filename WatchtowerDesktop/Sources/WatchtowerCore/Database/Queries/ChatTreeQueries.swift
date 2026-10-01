import Foundation
import GRDB

/// The main chat's branch-aware message access (spec §2.3). Discuss chats
/// keep using `ChatMessageQueries` (linear, no leaf) — a conversation whose
/// leaf is NULL reads in id order here too, the same fallback Go's
/// `ActiveChatPath` applies.
package enum ChatTreeQueries {
    package static func activePath(_ db: Database, conversationID: Int64) throws -> [ChatMessageRecord] {
        let all = try allMessages(db, conversationID: conversationID)
        return try resolvePath(db, conversationID: conversationID, all: all).path
    }

    package static func thread(_ db: Database, conversationID: Int64) throws -> [ChatThreadItem] {
        let all = try allMessages(db, conversationID: conversationID)
        let resolved = try resolvePath(db, conversationID: conversationID, all: all)
        let steps = try ChatStepQueries.fetch(db, messageIDs: resolved.path.map(\.id))
        let attachments = try ChatAttachmentQueries.fetchByMessages(db, messageIDs: resolved.path.map(\.id))
        return resolved.path.map { message in
            // Without a leaf there are no branches (legacy / never-branched chat).
            let sibs = resolved.tree.map { $0.siblings(of: message.id) } ?? [message.id]
            return ChatThreadItem(
                message: message,
                steps: steps[message.id] ?? [],
                siblingIndex: (sibs.firstIndex(of: message.id) ?? 0) + 1,
                siblingCount: max(sibs.count, 1),
                attachments: attachments[message.id] ?? []
            )
        }
    }

    package static func siblings(_ db: Database, messageID: Int64) throws -> [ChatMessageRecord] {
        try ChatMessageRecord.fetchAll(db, sql: """
            SELECT * FROM chat_messages
            WHERE conversation_id = (SELECT conversation_id FROM chat_messages WHERE id = ?)
              AND parent_id IS (SELECT parent_id FROM chat_messages WHERE id = ?)
            ORDER BY id
            """, arguments: [messageID, messageID])
    }

    /// The most recently written message of any branch — what a resumed
    /// provider session last saw, when that turn ran on the same provider.
    package static func newestMessage(_ db: Database, conversationID: Int64) throws -> ChatMessageRecord? {
        try ChatMessageRecord.fetchOne(
            db, sql: "SELECT * FROM chat_messages WHERE conversation_id = ? ORDER BY id DESC LIMIT 1",
            arguments: [conversationID]
        )
    }

    @discardableResult
    package static func insertUser(
        _ db: Database, conversationID: Int64, parentID: Int64?, text: String, turnID: String
    ) throws -> ChatMessageRecord {
        try insert(db, NewMessage(conversationID: conversationID, parentID: parentID, role: "user", text: text,
                                  turnID: turnID, status: "complete", provider: nil, model: nil))
    }

    /// The assistant row is created empty and `partial` BEFORE the turn is
    /// sent, so a crash at any point leaves a row the owner can Continue.
    @discardableResult
    package static func insertAssistant(
        _ db: Database, conversationID: Int64, parentID: Int64?, turnID: String, provider: String, model: String
    ) throws -> ChatMessageRecord {
        try insert(db, NewMessage(conversationID: conversationID, parentID: parentID, role: "assistant", text: "",
                                  turnID: turnID, status: "partial", provider: provider,
                                  model: model.isEmpty ? nil : model))
    }

    /// `errorMessage` is the session's own text for a failed turn, shown
    /// under the generic phrase of `errorCode`.
    package static func updateAssistant(
        _ db: Database, id: Int64, text: String, status: String, tokensIn: Int?, tokensOut: Int?,
        errorCode: String?, errorMessage: String?
    ) throws {
        try db.execute(sql: """
            UPDATE chat_messages SET text = ?, status = ?, tokens_in = ?, tokens_out = ?, error_code = ?, error_message = ?
            WHERE id = ?
            """, arguments: [text, status, tokensIn, tokensOut, errorCode, errorMessage, id])
    }

    package static func setModel(_ db: Database, messageID: Int64, model: String) throws {
        try db.execute(sql: "UPDATE chat_messages SET model = ? WHERE id = ?", arguments: [model, messageID])
    }

    package static func setActiveLeaf(_ db: Database, conversationID: Int64, messageID: Int64) throws {
        try db.execute(
            sql: "UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?",
            arguments: [messageID, conversationID]
        )
    }

    /// Show `siblingID`'s branch: the leaf moves to the newest leaf under it.
    package static func selectSibling(_ db: Database, conversationID: Int64, siblingID: Int64) throws {
        let tree = ChatTree(nodes: try allMessages(db, conversationID: conversationID).map(node))
        try setActiveLeaf(db, conversationID: conversationID, messageID: tree.newestLeaf(under: siblingID))
    }

    // MARK: - Private

    private struct NewMessage {
        let conversationID: Int64
        let parentID: Int64?
        let role: String
        let text: String
        let turnID: String
        let status: String
        let provider: String?
        let model: String?
    }

    private static func insert(_ db: Database, _ m: NewMessage) throws -> ChatMessageRecord {
        try db.execute(sql: """
            INSERT INTO chat_messages (conversation_id, parent_id, role, text, created_at, turn_id, status, provider, model)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [m.conversationID, m.parentID, m.role, m.text, Date().timeIntervalSince1970,
                             m.turnID, m.status, m.provider, m.model])
        let id = db.lastInsertedRowID
        try setActiveLeaf(db, conversationID: m.conversationID, messageID: id)
        try ChatConversationQueries.touch(db, id: m.conversationID)
        guard let row = try ChatMessageRecord.fetchOne(db, sql: "SELECT * FROM chat_messages WHERE id = ?", arguments: [id]) else {
            throw DatabaseError(message: "chat message \(id) vanished after insert")
        }
        return row
    }

    private static func allMessages(_ db: Database, conversationID: Int64) throws -> [ChatMessageRecord] {
        try ChatMessageRecord.fetchAll(
            db, sql: "SELECT * FROM chat_messages WHERE conversation_id = ? ORDER BY id", arguments: [conversationID]
        )
    }

    private static func node(_ m: ChatMessageRecord) -> ChatTree.Node {
        ChatTree.Node(id: m.id, parentID: m.parentID)
    }

    private static func resolvePath(
        _ db: Database, conversationID: Int64, all: [ChatMessageRecord]
    ) throws -> (path: [ChatMessageRecord], tree: ChatTree?) {
        let leaf = try Int64.fetchOne(
            db, sql: "SELECT active_leaf_message_id FROM chat_conversations WHERE id = ?", arguments: [conversationID]
        )
        guard let leaf else { return (all, nil) }
        let tree = ChatTree(nodes: all.map(node))
        let ids = tree.path(toLeaf: leaf)
        guard !ids.isEmpty else { return (all, nil) }
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        return (ids.compactMap { byID[$0] }, tree)
    }
}

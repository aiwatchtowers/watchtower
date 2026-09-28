import Foundation
import GRDB

/// `chat_attachments` — files sent with (or pending for) a chat message.
package enum ChatAttachmentQueries {
    private static func ownerColumns(_ owner: ChatAttachmentOwner) -> (conversationID: Int64?, projectID: Int64?) {
        switch owner {
        case .conversation(let id): return (id, nil)
        case .project(let id): return (nil, id)
        }
    }

    package static func insert(
        _ db: Database,
        owner: ChatAttachmentOwner,
        name: String,
        mime: String,
        size: Int64,
        path: String,
        sha256: String
    ) throws -> ChatAttachment {
        let columns = ownerColumns(owner)
        try db.execute(sql: """
            INSERT INTO chat_attachments (conversation_id, project_id, name, mime, size, path, sha256, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [columns.conversationID, columns.projectID, name, mime, size, path, sha256,
                             Date().timeIntervalSince1970])
        guard let row = try ChatAttachment.fetchOne(
            db, sql: "SELECT * FROM chat_attachments WHERE id = ?", arguments: [db.lastInsertedRowID]) else {
            throw DatabaseError(message: "chat attachment missing right after insert")
        }
        return row
    }

    /// A stored file with this content for the same owner (storage dedupe).
    package static func existingPath(_ db: Database, owner: ChatAttachmentOwner, sha256: String) throws -> String? {
        switch owner {
        case .conversation(let id):
            return try String.fetchOne(db, sql: """
                SELECT path FROM chat_attachments WHERE conversation_id = ? AND sha256 = ? ORDER BY id LIMIT 1
                """, arguments: [id, sha256])
        case .project(let id):
            return try String.fetchOne(db, sql: """
                SELECT path FROM chat_attachments WHERE project_id = ? AND sha256 = ? ORDER BY id LIMIT 1
                """, arguments: [id, sha256])
        }
    }

    /// Links pending (message-less) rows to the message they were sent with.
    /// Never steals a row a previous link already claimed.
    package static func link(_ db: Database, attachmentIDs: [Int64], messageID: Int64) throws {
        guard !attachmentIDs.isEmpty else { return }
        var arguments: StatementArguments = [messageID]
        arguments += StatementArguments(attachmentIDs)
        try db.execute(sql: """
            UPDATE chat_attachments SET message_id = ?
            WHERE id IN (\(databaseQuestionMarks(count: attachmentIDs.count))) AND message_id IS NULL
            """, arguments: arguments)
    }

    package static func fetchByMessages(_ db: Database, messageIDs: [Int64]) throws -> [Int64: [ChatAttachment]] {
        guard !messageIDs.isEmpty else { return [:] }
        let rows = try ChatAttachment.fetchAll(db, sql: """
            SELECT * FROM chat_attachments WHERE message_id IN (\(databaseQuestionMarks(count: messageIDs.count))) ORDER BY id
            """, arguments: StatementArguments(messageIDs))
        var out: [Int64: [ChatAttachment]] = [:]
        for row in rows {
            guard let messageID = row.messageID else { continue }
            out[messageID, default: []].append(row)
        }
        return out
    }

    /// A conversation's unsent files (not linked to any message yet): the
    /// composer's pending set when that conversation is opened again.
    package static func fetchPending(_ db: Database, conversationID: Int64) throws -> [ChatAttachment] {
        try ChatAttachment.fetchAll(db, sql: """
            SELECT * FROM chat_attachments WHERE conversation_id = ? AND message_id IS NULL ORDER BY id
            """, arguments: [conversationID])
    }

    package static func delete(_ db: Database, id: Int64) throws {
        try db.execute(sql: "DELETE FROM chat_attachments WHERE id = ?", arguments: [id])
    }

    package static func referenceCount(_ db: Database, path: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_attachments WHERE path = ?", arguments: [path]) ?? 0
    }
}

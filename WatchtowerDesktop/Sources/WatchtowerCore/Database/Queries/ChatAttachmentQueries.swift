import Foundation
import GRDB

/// `chat_attachments` — files sent with (or pending for) a chat message.
package enum ChatAttachmentQueries {
    package static func ownerColumns(_ owner: ChatAttachmentOwner) -> (conversationID: Int64?, projectID: Int64?) {
        switch owner {
        case .conversation(let id): return (id, nil)
        case .project(let id): return (nil, id)
        }
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

    package static func referenceCount(_ db: Database, path: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_attachments WHERE path = ?", arguments: [path]) ?? 0
    }
}

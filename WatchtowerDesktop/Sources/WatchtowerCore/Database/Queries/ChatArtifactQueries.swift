import Foundation
import GRDB

package enum ChatArtifactQueries {
    /// Stores one version. Non-edit save from the message that produced the
    /// key's current latest (non-edited) version overwrites it in place —
    /// re-persisting a turn is idempotent and the last same-key block of one
    /// message wins. Everything else inserts `max(version) + 1`.
    @discardableResult
    package static func saveVersion(
        _ db: Database, conversationID: Int64, messageID: Int64, draft: ArtifactDraft, edited: Bool
    ) throws -> ChatArtifact {
        let metaJSON = try encodeMeta(draft.meta)
        if !edited, let latest = try latest(db, conversationID: conversationID, key: draft.key),
           latest.messageID == messageID, !latest.edited {
            // Unchecked: `latest` was read in this same write transaction.
            try db.execute(sql: """
                UPDATE chat_artifacts SET kind = ?, title = ?, content = ?, meta_json = ? WHERE id = ?
                """, arguments: [draft.kind, draft.title, draft.content, metaJSON, latest.id])
            return try fetch(db, id: latest.id)
        }
        let maxVersion = try Int.fetchOne(db, sql: """
            SELECT MAX(version) FROM chat_artifacts WHERE conversation_id = ? AND artifact_key = ?
            """, arguments: [conversationID, draft.key]) ?? 0
        try db.execute(sql: """
            INSERT INTO chat_artifacts
                (conversation_id, message_id, artifact_key, version, kind, title, content, meta_json, edited, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [conversationID, messageID, draft.key, maxVersion + 1, draft.kind, draft.title,
                             draft.content, metaJSON, edited ? 1 : 0, Date().timeIntervalSince1970])
        return try fetch(db, id: db.lastInsertedRowID)
    }

    package static func latest(_ db: Database, conversationID: Int64, key: String) throws -> ChatArtifact? {
        try ChatArtifact.fetchOne(db, sql: """
            SELECT * FROM chat_artifacts WHERE conversation_id = ? AND artifact_key = ? ORDER BY version DESC LIMIT 1
            """, arguments: [conversationID, key])
    }

    package static func versions(_ db: Database, conversationID: Int64, key: String) throws -> [ChatArtifact] {
        try ChatArtifact.fetchAll(db, sql: """
            SELECT * FROM chat_artifacts WHERE conversation_id = ? AND artifact_key = ? ORDER BY version
            """, arguments: [conversationID, key])
    }

    /// Parses a finished assistant message (`final: true`) and stores every artifact.
    @discardableResult
    package static func persistArtifacts(
        _ db: Database, conversationID: Int64, messageID: Int64, text: String
    ) throws -> [ChatArtifact] {
        try ArtifactParser.parse(text, final: true).artifacts.map {
            try saveVersion(db, conversationID: conversationID, messageID: messageID, draft: $0, edited: false)
        }
    }

    /// message id → (artifact key → the non-edited version that message produced), for card badges.
    package static func versionsByMessage(_ db: Database, messageIDs: [Int64]) throws -> [Int64: [String: Int]] {
        guard !messageIDs.isEmpty else { return [:] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT message_id, artifact_key, MAX(version) AS version FROM chat_artifacts
            WHERE message_id IN (\(databaseQuestionMarks(count: messageIDs.count))) AND edited = 0
            GROUP BY message_id, artifact_key
            """, arguments: StatementArguments(messageIDs))
        var out: [Int64: [String: Int]] = [:]
        for row in rows {
            let messageID: Int64 = row["message_id"]
            let key: String = row["artifact_key"]
            out[messageID, default: [:]][key] = row["version"]
        }
        return out
    }

    private static func fetch(_ db: Database, id: Int64) throws -> ChatArtifact {
        guard let artifact = try ChatArtifact.fetchOne(db, sql: "SELECT * FROM chat_artifacts WHERE id = ?", arguments: [id]) else {
            throw DatabaseError(message: "chat artifact \(id) missing right after write")
        }
        return artifact
    }

    private static func encodeMeta(_ meta: [String: String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(meta)
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw DatabaseError(message: "meta JSON encoding produced non-UTF-8 data")
        }
        return json
    }
}

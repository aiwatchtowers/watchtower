import Foundation
import GRDB
import WatchtowerChatText

package enum ChatArtifactQueries {

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

    // MARK: - Kept artifacts (chat knowledge)

    /// The kept version of an artifact key, `nil` when it is not kept.
    package static func keptVersion(_ db: Database, conversationID: Int64, artifactKey: String) throws -> Int? {
        try Int.fetchOne(db, sql: """
            SELECT version FROM chat_knowledge_artifacts WHERE conversation_id = ? AND artifact_key = ?
            """, arguments: [conversationID, artifactKey])
    }

    /// The artifact keys of a conversation that are pinned as knowledge.
    package static func keptKeys(_ db: Database, conversationID: Int64) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: """
            SELECT artifact_key FROM chat_knowledge_artifacts WHERE conversation_id = ?
            """, arguments: [conversationID]))
    }
}

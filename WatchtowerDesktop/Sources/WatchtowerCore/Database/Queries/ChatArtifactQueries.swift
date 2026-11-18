import Foundation
import GRDB
import WatchtowerChatText

package enum ChatArtifactQueries {

    package static func versions(_ db: Database, conversationID: Int64, key: String) throws -> [ChatArtifact] {
        try ChatArtifact.fetchAll(db, sql: """
            SELECT * FROM chat_artifacts WHERE conversation_id = ? AND artifact_key = ? ORDER BY version
            """, arguments: [conversationID, key])
    }

    // MARK: - Kept artifacts (chat knowledge)

    /// The kept version of an artifact key, `nil` when it is not kept.
    package static func keptVersion(_ db: Database, conversationID: Int64, artifactKey: String) throws -> Int? {
        try Int.fetchOne(db, sql: """
            SELECT version FROM chat_knowledge_artifacts WHERE conversation_id = ? AND artifact_key = ?
            """, arguments: [conversationID, artifactKey])
    }

    package static func fetch(_ db: Database, id: Int64) throws -> ChatArtifact {
        guard let artifact = try ChatArtifact.fetchOne(db, sql: "SELECT * FROM chat_artifacts WHERE id = ?", arguments: [id]) else {
            throw DatabaseError(message: "chat artifact \(id) missing right after write")
        }
        return artifact
    }

}

/// Why an artifact cannot be pinned as knowledge.
package enum ChatArtifactKeepError: Error {
    /// The conversation used the Live Slack connector (LIVE-01).
    case liveSlack
}

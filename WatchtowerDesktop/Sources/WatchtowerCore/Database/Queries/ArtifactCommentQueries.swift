import Foundation
import GRDB

package enum ArtifactCommentError: LocalizedError, Equatable {
    case emptyBody
    case emptyQuote

    package var errorDescription: String? {
        switch self {
        case .emptyBody: "Write a comment first."
        case .emptyQuote: "Select the text to comment on."
        }
    }
}

/// `chat_artifact_comments` (migration 00082). The Desktop is the only
/// writer; nothing here reaches the assistant — sent comments travel only in
/// the owner's own chat message.
package enum ArtifactCommentQueries {
    package static func comments(_ db: Database, conversationID: Int64, key: String) throws -> [ArtifactComment] {
        try ArtifactComment.fetchAll(db, sql: """
            SELECT * FROM chat_artifact_comments WHERE conversation_id = ? AND artifact_key = ? ORDER BY id
            """, arguments: [conversationID, key])
    }

}

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

    @discardableResult
    package static func add(
        _ db: Database,
        conversationID: Int64,
        key: String,
        version: Int,
        anchor: CommentAnchor,
        body: String,
        now: Date = Date()
    ) throws -> Int64 {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ArtifactCommentError.emptyBody }
        guard !anchor.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArtifactCommentError.emptyQuote
        }
        try db.execute(sql: """
            INSERT INTO chat_artifact_comments
                (conversation_id, artifact_key, artifact_version, body,
                 anchor_quote, anchor_prefix, anchor_suffix, anchor_heading, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [conversationID, key, version, trimmed,
                             anchor.quote, anchor.prefix, anchor.suffix, anchor.heading, now.timeIntervalSince1970])
        return db.lastInsertedRowID
    }

    /// An unsent comment is the owner's private draft: deleting it leaves no
    /// trace. A sent one is part of the conversation — it can only be resolved.
    @discardableResult
    package static func deleteUnsent(_ db: Database, id: Int64) throws -> Bool {
        try db.execute(sql: "DELETE FROM chat_artifact_comments WHERE id = ? AND status = 'open'", arguments: [id])
        return db.changesCount > 0
    }

    @discardableResult
    package static func resolve(_ db: Database, id: Int64) throws -> Bool {
        try db.execute(sql: """
            UPDATE chat_artifact_comments SET status = 'resolved' WHERE id = ? AND status IN ('sent', 'outdated')
            """, arguments: [id])
        return db.changesCount > 0
    }

    /// Marks exactly `ids` sent, and only those still unsent — a comment added
    /// after the message was composed, or one sent earlier, is never touched.
    /// Runs inside the transaction that persists the owner message.
    @discardableResult
    package static func markSent(_ db: Database, ids: [Int64], at date: Date) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        var arguments: StatementArguments = [date.timeIntervalSince1970]
        arguments += StatementArguments(ids)
        try db.execute(sql: """
            UPDATE chat_artifact_comments SET status = 'sent', sent_at = ?
            WHERE status = 'open' AND id IN (\(databaseQuestionMarks(count: ids.count)))
            """, arguments: arguments)
        return db.changesCount
    }

    /// Applies a re-anchor plan: found live comments move onto `version`, lost
    /// ones become outdated (keeping the version they were last found on).
    /// Resolved and outdated rows are never touched.
    package static func apply(_ db: Database, plan: ArtifactCommentReanchor.Plan, version: Int) throws {
        for id in plan.moved {
            try db.execute(sql: """
                UPDATE chat_artifact_comments SET artifact_version = ? WHERE id = ? AND status IN ('open', 'sent')
                """, arguments: [version, id])
        }
        for id in plan.lost {
            try db.execute(sql: """
                UPDATE chat_artifact_comments SET status = 'outdated' WHERE id = ? AND status IN ('open', 'sent')
                """, arguments: [id])
        }
    }
}

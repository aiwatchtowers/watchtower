import Foundation
import GRDB

/// One code question in a workbench's Questions tab (spec 2026-10-02 §9.4).
package struct CodeQuestionListItem: Equatable, Identifiable, Sendable {
    package let conversationID: Int64
    /// Relative to the workbench folder; "" for a question asked from Open
    /// Quickly with no file open.
    package let path: String
    /// The cursor line it was asked from; 0 with no file.
    package let line: Int
    /// The owner's first message; nil until one was sent.
    package let firstQuestion: String?
    package let createdAt: Date

    package init(conversationID: Int64, path: String, line: Int, firstQuestion: String?, createdAt: Date) {
        self.conversationID = conversationID
        self.path = path
        self.line = line
        self.firstQuestion = firstQuestion
        self.createdAt = createdAt
    }

    package var id: Int64 { conversationID }

    package var origin: CodeQuestionOrigin {
        CodeQuestionOrigin(path: path, line: line, selection: nil)
    }

    /// "path:line"; nil when no file was open.
    package var originLabel: String? {
        path.isEmpty ? nil : "\(path):\(line)"
    }
}

/// The code questions of a workbench: `chat_conversations` rows with
/// `context_type = 'code_question'` and `context_id =
/// '<workbench id>:<path>:<line>'` (owner decision 2). The main chat never
/// reads them (`context_type IS NULL` there).
package enum CodeQuestionList {
    package static let contextType = "code_question"

    /// Newest first. The `<id>:` prefix is matched exactly, so workbench 1
    /// never lists workbench 10's questions.
    package static func fetch(_ db: Database, workbenchID: Int64) throws -> [CodeQuestionListItem] {
        let prefix = "\(workbenchID):"
        let rows = try Row.fetchAll(db, sql: """
            SELECT c.id, c.context_id, c.created_at,
                   (SELECT m.text FROM chat_messages m
                     WHERE m.conversation_id = c.id AND m.role = 'user'
                     ORDER BY m.id LIMIT 1) AS first_question
            FROM chat_conversations c
            WHERE c.context_type = ? AND substr(c.context_id, 1, length(?)) = ?
            ORDER BY c.created_at DESC, c.id DESC
            """, arguments: [contextType, prefix, prefix])
        return rows.compactMap { row in
            let contextID: String = row["context_id"]
            guard let origin = origin(contextID: contextID, workbenchID: workbenchID) else { return nil }
            let createdAt: Double = row["created_at"]
            return CodeQuestionListItem(
                conversationID: row["id"], path: origin.path, line: origin.line,
                firstQuestion: row["first_question"], createdAt: Date(timeIntervalSince1970: createdAt))
        }
    }

    /// How many code questions the workbench has (the delete takes them,
    /// PROJ-02).
    package static func count(_ db: Database, workbenchID: Int64) throws -> Int {
        let prefix = "\(workbenchID):"
        return try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM chat_conversations
            WHERE context_type = ? AND substr(context_id, 1, length(?)) = ?
            """, arguments: [contextType, prefix, prefix]) ?? 0
    }

    /// The origin a `context_id` names, or nil when it is not one of
    /// `workbenchID`'s. The line follows the last colon (a path may hold
    /// colons).
    package static func origin(contextID: String, workbenchID: Int64) -> CodeQuestionOrigin? {
        let prefix = "\(workbenchID):"
        guard contextID.hasPrefix(prefix) else { return nil }
        let rest = contextID.dropFirst(prefix.count)
        guard let colon = rest.lastIndex(of: ":"), let line = Int(rest[rest.index(after: colon)...]) else { return nil }
        return CodeQuestionOrigin(path: String(rest[..<colon]), line: line, selection: nil)
    }

    /// Deletes a code question with its messages (and their search rows,
    /// through the cascade and the FTS triggers); true when one was deleted.
    @discardableResult
    package static func delete(_ db: Database, conversationID: Int64) throws -> Bool {
        try db.execute(sql: "DELETE FROM chat_conversations WHERE id = ? AND context_type = ?",
                       arguments: [conversationID, contextType])
        return db.changesCount > 0
    }
}

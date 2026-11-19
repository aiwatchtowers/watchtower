import Foundation
import GRDB

/// `chat_attachments` — files sent with (or pending for) a chat message.
package enum ChatAttachmentQueries {

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
}

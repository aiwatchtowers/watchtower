import Foundation
import GRDB

package struct ChatSearchHit: Identifiable, Equatable, Sendable {
    package let conversationID: Int64
    /// nil for a title match.
    package let messageID: Int64?
    package let title: String
    /// Match terms wrapped in `ChatSearchQueries.markStart`/`markEnd`.
    package let snippet: String

    package init(conversationID: Int64, messageID: Int64?, title: String, snippet: String) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.title = title
        self.snippet = snippet
    }

    package var id: String { "\(conversationID):\(messageID ?? 0)" }

    /// The snippet with markers removed and matched terms bold.
    package var attributedSnippet: AttributedString {
        var out = AttributedString()
        var buffer = ""
        var bold = false
        func flush() {
            var part = AttributedString(buffer)
            if bold { part.inlinePresentationIntent = .stronglyEmphasized }
            out += part
            buffer = ""
        }
        for ch in snippet {
            if String(ch) == ChatSearchQueries.markStart {
                flush()
                bold = true
            } else if String(ch) == ChatSearchQueries.markEnd {
                flush()
                bold = false
            } else {
                buffer.append(ch)
            }
        }
        flush()
        return out
    }
}

/// ⌘K search over the main chat's history: conversation titles (LIKE) and
/// message text (`chat_fts`, kept by triggers from migration 00076).
package enum ChatSearchQueries {
    package static let markStart = "\u{2}"
    package static let markEnd = "\u{3}"

    /// Owner text → an FTS5 query: every letter/number run quoted (so FTS
    /// syntax in the input is inert) and prefix-matched (`*`), AND-joined.
    package static func ftsQuery(_ raw: String) -> String? {
        let tokens = raw.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    package static func search(_ db: Database, query: String, limit: Int = 30) throws -> [ChatSearchHit] {
        guard let match = ftsQuery(query) else { return [] }
        let titles = try titleMatches(db, query: query.trimmingCharacters(in: .whitespacesAndNewlines), limit: limit)
        let messages = try messageMatches(db, match: match, limit: limit)
        return Array((titles + messages).prefix(limit))
    }

    private static func titleMatches(_ db: Database, query: String, limit: Int) throws -> [ChatSearchHit] {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, title FROM chat_conversations
            WHERE context_type IS NULL AND archived_at IS NULL AND title LIKE ? ESCAPE '\\'
            ORDER BY updated_at DESC LIMIT ?
            """, arguments: ["%\(escaped)%", limit])
        return rows.map { row in
            let title: String = row["title"]
            return ChatSearchHit(conversationID: row["id"], messageID: nil, title: title, snippet: title)
        }
    }

    private static func messageMatches(_ db: Database, match: String, limit: Int) throws -> [ChatSearchHit] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.conversation_id AS cid, m.id AS mid, c.title AS title,
                   snippet(chat_fts, 0, ?, ?, '…', 12) AS snip
            FROM chat_fts
            JOIN chat_messages m ON m.id = chat_fts.rowid
            JOIN chat_conversations c ON c.id = m.conversation_id
            WHERE chat_fts MATCH ? AND c.context_type IS NULL AND c.archived_at IS NULL
              AND m.role IN ('user', 'assistant')
            ORDER BY bm25(chat_fts) LIMIT ?
            """, arguments: [markStart, markEnd, match, limit])
        return rows.map { row in
            ChatSearchHit(conversationID: row["cid"], messageID: row["mid"], title: row["title"], snippet: row["snip"])
        }
    }
}

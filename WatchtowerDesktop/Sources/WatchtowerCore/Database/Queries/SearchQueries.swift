import GRDB

package enum SearchQueries {
    package static func search(
        _ db: Database, query: String, channelID: String? = nil, userID: String? = nil, limit: Int = 100
    ) throws -> [SearchResult] {
        // H5: sanitize FTS5 input — wrap each term in double quotes, strip operators
        let sanitized = sanitizeFTS5Query(query)
        guard !sanitized.isEmpty else { return [] }

        var conditions = ["messages_fts.text MATCH ?"]
        var args: [any DatabaseValueConvertible] = [sanitized]

        if let channelID {
            conditions.append("m.channel_id = ?")
            args.append(channelID)
        }
        if let userID {
            conditions.append("m.user_id = ?")
            args.append(userID)
        }

        args.append(limit)

        let sql = """
            SELECT m.*, c.name as channel_name, u.display_name as user_name,
                   snippet(messages_fts, 0, '<mark>', '</mark>', '...', 64) as snippet
            FROM messages m
            JOIN messages_fts ON messages_fts.channel_id = m.channel_id AND messages_fts.ts = m.ts
            JOIN channels c ON c.id = m.channel_id
            LEFT JOIN users u ON u.id = m.user_id
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY rank
            LIMIT ?
            """

        return try SearchResult.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    /// Sanitize user input for FTS5: wrap terms in double quotes, skip operators
    package static func sanitizeFTS5Query(_ input: String) -> String {
        let operators: Set<String> = ["AND", "OR", "NOT", "NEAR"]
        let words = input.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { !operators.contains($0.uppercased()) }
        return words
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
            .joined(separator: " ")
    }
}

package struct SearchResult: FetchableRecord, Decodable, Identifiable, Equatable {
    package let channelID: String
    package let ts: String
    package let userID: String
    package let text: String
    package let threadTS: String?
    package let replyCount: Int
    package let isEdited: Bool
    package let isDeleted: Bool
    package let subtype: String
    package let permalink: String
    package let tsUnix: Double
    package let rawJSON: String
    package let channelName: String?
    package let userName: String?
    package let snippet: String?

    package var id: String { "\(channelID)_\(ts)" }

    package enum CodingKeys: String, CodingKey {
        case ts, text, subtype, permalink, snippet
        case channelID = "channel_id"
        case userID = "user_id"
        case threadTS = "thread_ts"
        case replyCount = "reply_count"
        case isEdited = "is_edited"
        case isDeleted = "is_deleted"
        case tsUnix = "ts_unix"
        case rawJSON = "raw_json"
        case channelName = "channel_name"
        case userName = "user_name"
    }
}

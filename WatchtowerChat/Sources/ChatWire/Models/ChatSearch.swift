import Foundation

/// The `chat_search` slice, record `chat_search-<query hash>` (iPhone chat
/// spec §4.6): up to 50 hits of the Mac's ⌘K chat search for one query,
/// asked with `chat_search` and kept 5 minutes.
public struct ChatSearch: Decodable, Hashable, Sendable {
    /// The markers around a matched term in a snippet.
    public static let markStart = "\u{2}"
    public static let markEnd = "\u{3}"

    public struct Hit: Hashable, Sendable, Decodable {
        public let conversationID: Int64
        public let title: String
        /// Cap 200; matched terms between `markStart` and `markEnd`.
        public let snippet: String
        /// nil for a title match.
        public let messageID: Int64?
        public let date: Date

        public init(conversationID: Int64, title: String, snippet: String, messageID: Int64? = nil, date: Date) {
            self.conversationID = conversationID
            self.title = title
            self.snippet = snippet
            self.messageID = messageID
            self.date = date
        }

        // convertFromSnakeCase maps "conversation_id" -> "conversationId".
        enum CodingKeys: String, CodingKey {
            case conversationID = "conversationId"
            case title, snippet
            case messageID = "messageId"
            case date
        }
    }

    /// The query as the phone sent it.
    public let query: String
    public let hits: [Hit]

    public init(query: String, hits: [Hit]) {
        self.query = query
        self.hits = hits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        query = try c.decodeIfPresent(String.self, forKey: .query) ?? ""
        hits = try c.decodeIfPresent([Hit].self, forKey: .hits) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case query, hits
    }
}

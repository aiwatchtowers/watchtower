import GRDB
import Foundation

/// One idea/decision candidate inside a stream-digest topic — the phone
/// replica mirror of the desktop's `StreamCandidate` (WatchtowerCore),
/// column-for-column; keep the two in sync.
public struct StreamCandidate: Codable, Hashable {
    public let text: String
    public let author: String?
    public let ref: String?
}

/// One topic of a stream digest — the phone replica mirror of the desktop's
/// `StreamTopic` (WatchtowerCore), column-for-column; keep the two in sync.
public struct StreamTopic: Codable, Hashable {
    public let title: String
    public let summary: String?
    public let ideas: [StreamCandidate]?
    public let decisions: [StreamCandidate]?
}

/// A Gmail/Jira stream digest — the phone replica mirror of the desktop's
/// `StreamDigest` model (WatchtowerCore), decoded from the `stream_digest`
/// slice payload (the full `stream_digests` row); keep the two in sync.
public struct StreamDigest: FetchableRecord, Decodable, Identifiable, Equatable {
    public let id: Int
    public let source: String
    public let accountID: Int?
    public let scope: String
    public let periodFrom: String
    public let periodTo: String
    public let topicsJSON: String
    public let createdAt: String
    public let readAt: String?

    public enum CodingKeys: String, CodingKey {
        case id, source, scope
        case accountID = "account_id"
        case periodFrom = "period_from"
        case periodTo = "period_to"
        case topicsJSON = "topics_json"
        case createdAt = "created_at"
        case readAt = "read_at"
    }

    public var isRead: Bool { readAt != nil }

    private static let decoder = JSONDecoder()

    public var parsedTopics: [StreamTopic] {
        guard let data = topicsJSON.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([StreamTopic].self, from: data)) ?? []
    }
}

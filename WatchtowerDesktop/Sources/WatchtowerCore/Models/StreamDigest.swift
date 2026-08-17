import GRDB
import Foundation

package struct StreamCandidate: Codable, Hashable {
    package let text: String
    package let author: String?
    package let ref: String?
}

package struct StreamTopic: Codable, Hashable {
    package let title: String
    package let summary: String?
    package let ideas: [StreamCandidate]?
    package let decisions: [StreamCandidate]?
}

package struct StreamDigest: FetchableRecord, Decodable, Identifiable, Equatable {
    package let id: Int
    package let source: String
    package let accountID: Int?
    package let scope: String
    package let periodFrom: String
    package let periodTo: String
    package let topicsJSON: String
    package let createdAt: String
    package let readAt: String?

    package enum CodingKeys: String, CodingKey {
        case id, source, scope
        case accountID = "account_id"
        case periodFrom = "period_from"
        case periodTo = "period_to"
        case topicsJSON = "topics_json"
        case createdAt = "created_at"
        case readAt = "read_at"
    }

    package var isRead: Bool { readAt != nil }

    private static let decoder = JSONDecoder()

    package var parsedTopics: [StreamTopic] {
        guard let data = topicsJSON.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([StreamTopic].self, from: data)) ?? []
    }
}

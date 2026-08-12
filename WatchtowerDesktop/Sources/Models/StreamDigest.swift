import GRDB
import Foundation

struct StreamCandidate: Codable, Hashable {
    let text: String
    let author: String?
    let ref: String?
}

struct StreamTopic: Codable, Hashable {
    let title: String
    let summary: String?
    let ideas: [StreamCandidate]?
    let decisions: [StreamCandidate]?
}

struct StreamDigest: FetchableRecord, Decodable, Identifiable, Equatable {
    let id: Int
    let source: String
    let accountID: Int?
    let scope: String
    let periodFrom: String
    let periodTo: String
    let topicsJSON: String
    let createdAt: String
    let readAt: String?

    enum CodingKeys: String, CodingKey {
        case id, source, scope
        case accountID = "account_id"
        case periodFrom = "period_from"
        case periodTo = "period_to"
        case topicsJSON = "topics_json"
        case createdAt = "created_at"
        case readAt = "read_at"
    }

    var isRead: Bool { readAt != nil }

    private static let decoder = JSONDecoder()

    var parsedTopics: [StreamTopic] {
        guard let data = topicsJSON.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([StreamTopic].self, from: data)) ?? []
    }
}

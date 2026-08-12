import GRDB
import Foundation

package struct Digest: FetchableRecord, Decodable, Identifiable, Equatable {
    package let id: Int
    package let channelID: String
    package let periodFrom: Double
    package let periodTo: Double
    package let type: String
    package let summary: String
    package let topics: String
    package let decisions: String
    package let tracksJSON: String
    package let messageCount: Int
    package let model: String
    package let inputTokens: Int?
    package let outputTokens: Int?
    package let costUSD: Double?
    package let createdAt: String
    package let readAt: String?
    package let runningSummary: String?

    package enum CodingKeys: String, CodingKey {
        case id, type, summary, topics, decisions, model
        case channelID = "channel_id"
        case periodFrom = "period_from"
        case periodTo = "period_to"
        case tracksJSON = "action_items"
        case messageCount = "message_count"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUSD = "cost_usd"
        case createdAt = "created_at"
        case readAt = "read_at"
        case runningSummary = "running_summary"
    }

    package var isRead: Bool { readAt != nil }

    // M3: cache parsed JSON via lazy static decoder
    private static let decoder = JSONDecoder()

    package var parsedDecisions: [Decision] {
        guard let data = decisions.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([Decision].self, from: data)) ?? []
    }

    package var parsedTracks: [DigestTrack] {
        guard let data = tracksJSON.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([DigestTrack].self, from: data)) ?? []
    }

    package var parsedTopics: [String] {
        guard let data = topics.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([String].self, from: data)) ?? []
    }

    package var parsedRunningSummary: RunningSummary? {
        guard let raw = runningSummary, !raw.isEmpty,
              let data = raw.data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(RunningSummary.self, from: data)
    }
}

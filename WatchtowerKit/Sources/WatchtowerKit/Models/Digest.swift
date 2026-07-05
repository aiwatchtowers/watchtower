import GRDB
import Foundation

public struct Digest: FetchableRecord, Decodable, Identifiable, Equatable {
    public let id: Int
    public let channelID: String
    public let periodFrom: Double
    public let periodTo: Double
    public let type: String
    public let summary: String
    public let topics: String
    public let decisions: String
    public let tracksJSON: String
    public let messageCount: Int
    public let model: String
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let costUSD: Double?
    public let createdAt: String
    public let readAt: String?
    public let runningSummary: String?

    enum CodingKeys: String, CodingKey {
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

    public var isRead: Bool { readAt != nil }

    // M3: cache parsed JSON via lazy static decoder
    private static let decoder = JSONDecoder()

    public var parsedDecisions: [Decision] {
        guard let data = decisions.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([Decision].self, from: data)) ?? []
    }

    public var parsedTracks: [DigestTrack] {
        guard let data = tracksJSON.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([DigestTrack].self, from: data)) ?? []
    }

    public var parsedTopics: [String] {
        guard let data = topics.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([String].self, from: data)) ?? []
    }

    public var parsedRunningSummary: RunningSummary? {
        guard let raw = runningSummary, !raw.isEmpty,
              let data = raw.data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(RunningSummary.self, from: data)
    }
}

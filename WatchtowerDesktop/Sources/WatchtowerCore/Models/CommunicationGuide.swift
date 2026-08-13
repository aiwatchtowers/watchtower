import GRDB
import Foundation

package struct CommunicationGuide: FetchableRecord, Decodable, Identifiable, Equatable {
    package let id: Int
    package let userID: String
    package let periodFrom: Double
    package let periodTo: Double
    package let messageCount: Int
    package let channelsActive: Int
    package let threadsInitiated: Int
    package let threadsReplied: Int
    package let avgMessageLength: Double
    package let activeHoursJSON: String
    package let volumeChangePct: Double
    package let summary: String
    package let communicationPreferences: String
    package let availabilityPatterns: String
    package let decisionProcess: String
    package let situationalTactics: String
    package let effectiveApproaches: String
    package let recommendations: String
    package let relationshipContext: String
    package let model: String
    package let inputTokens: Int?
    package let outputTokens: Int?
    package let costUSD: Double?
    package let createdAt: String

    package enum CodingKeys: String, CodingKey {
        case id, summary, model, recommendations
        case userID = "user_id"
        case periodFrom = "period_from"
        case periodTo = "period_to"
        case messageCount = "message_count"
        case channelsActive = "channels_active"
        case threadsInitiated = "threads_initiated"
        case threadsReplied = "threads_replied"
        case avgMessageLength = "avg_message_length"
        case activeHoursJSON = "active_hours_json"
        case volumeChangePct = "volume_change_pct"
        case communicationPreferences = "communication_preferences"
        case availabilityPatterns = "availability_patterns"
        case decisionProcess = "decision_process"
        case situationalTactics = "situational_tactics"
        case effectiveApproaches = "effective_approaches"
        case relationshipContext = "relationship_context"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUSD = "cost_usd"
        case createdAt = "created_at"
    }

    private static let decoder = JSONDecoder()

    package var parsedSituationalTactics: [String] {
        guard let data = situationalTactics.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([String].self, from: data)) ?? []
    }

    package var parsedEffectiveApproaches: [String] {
        guard let data = effectiveApproaches.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([String].self, from: data)) ?? []
    }

    package var parsedRecommendations: [String] {
        guard let data = recommendations.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([String].self, from: data)) ?? []
    }

    package var parsedActiveHours: [String: Int] {
        guard let data = activeHoursJSON.data(using: .utf8) else { return [:] }
        return (try? Self.decoder.decode([String: Int].self, from: data)) ?? [:]
    }

    package var periodFromDate: Date {
        Date(timeIntervalSince1970: periodFrom)
    }

    package var periodToDate: Date {
        Date(timeIntervalSince1970: periodTo)
    }
}

package struct GuideSummary: FetchableRecord, Decodable, Identifiable, Equatable {
    package let id: Int
    package let periodFrom: Double
    package let periodTo: Double
    package let summary: String
    package let tips: String
    package let model: String
    package let inputTokens: Int?
    package let outputTokens: Int?
    package let costUSD: Double?
    package let createdAt: String

    package enum CodingKeys: String, CodingKey {
        case id, summary, model, tips
        case periodFrom = "period_from"
        case periodTo = "period_to"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUSD = "cost_usd"
        case createdAt = "created_at"
    }

    private static let decoder = JSONDecoder()

    package var parsedTips: [String] {
        guard let data = tips.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([String].self, from: data)) ?? []
    }

    package var periodFromDate: Date {
        Date(timeIntervalSince1970: periodFrom)
    }

    package var periodToDate: Date {
        Date(timeIntervalSince1970: periodTo)
    }
}

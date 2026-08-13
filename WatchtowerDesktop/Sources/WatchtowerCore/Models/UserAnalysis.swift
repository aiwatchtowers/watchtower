import GRDB
import Foundation

package struct UserAnalysis: FetchableRecord, Decodable, Identifiable, Equatable {
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
    package let communicationStyle: String
    package let decisionRole: String
    package let redFlags: String
    package let highlights: String
    package let styleDetails: String
    package let recommendations: String
    package let concerns: String
    package let accomplishments: String
    package let model: String
    package let inputTokens: Int?
    package let outputTokens: Int?
    package let costUSD: Double?
    package let createdAt: String

    package enum CodingKeys: String, CodingKey {
        case id, summary, model, highlights
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
        case communicationStyle = "communication_style"
        case decisionRole = "decision_role"
        case redFlags = "red_flags"
        case styleDetails = "style_details"
        case recommendations
        case concerns, accomplishments
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUSD = "cost_usd"
        case createdAt = "created_at"
    }

    private static let decoder = JSONDecoder()

    package var parsedRedFlags: [String] {
        guard let data = redFlags.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([String].self, from: data)) ?? []
    }

    package var parsedHighlights: [String] {
        guard let data = highlights.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([String].self, from: data)) ?? []
    }

    package var parsedRecommendations: [String] {
        guard let data = recommendations.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([String].self, from: data)) ?? []
    }

    package var parsedConcerns: [String] {
        guard let data = concerns.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([String].self, from: data)) ?? []
    }

    package var parsedAccomplishments: [String] {
        guard let data = accomplishments.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([String].self, from: data)) ?? []
    }

    package var hasConcerns: Bool {
        !parsedConcerns.isEmpty
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

    package var hasRedFlags: Bool {
        !parsedRedFlags.isEmpty
    }

    package var styleEmoji: String {
        switch communicationStyle.lowercased() {
        case "driver": return "🚀"
        case "collaborator": return "🤝"
        case "executor": return "⚡"
        case "observer": return "👀"
        case "facilitator": return "🎯"
        default: return "💬"
        }
    }
}

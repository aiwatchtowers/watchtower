import Foundation
import GRDB

public struct PeopleCard: FetchableRecord, Decodable, Identifiable, Equatable {
    public var id: Int64
    public var userID: String
    public var periodFrom: Double
    public var periodTo: Double
    public var messageCount: Int
    public var channelsActive: Int
    public var threadsInitiated: Int
    public var threadsReplied: Int
    public var avgMessageLength: Double
    public var activeHoursJSON: String
    public var volumeChangePct: Double
    public var summary: String
    public var communicationStyle: String
    public var decisionRole: String
    public var redFlags: String      // JSON array
    public var highlights: String    // JSON array
    public var accomplishments: String // JSON array
    public var communicationGuide: String
    public var decisionStyle: String
    public var tactics: String       // JSON array
    public var relationshipContext: String
    public var status: String
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var costUSD: Double
    public var promptVersion: Int
    public var createdAt: String

    // Column mapping
    enum CodingKeys: String, CodingKey {
        case id, userID = "user_id", periodFrom = "period_from", periodTo = "period_to"
        case messageCount = "message_count", channelsActive = "channels_active"
        case threadsInitiated = "threads_initiated", threadsReplied = "threads_replied"
        case avgMessageLength = "avg_message_length", activeHoursJSON = "active_hours_json"
        case volumeChangePct = "volume_change_pct"
        case summary, communicationStyle = "communication_style", decisionRole = "decision_role"
        case redFlags = "red_flags", highlights, accomplishments
        case communicationGuide = "communication_guide", decisionStyle = "decision_style"
        case tactics, relationshipContext = "relationship_context", status
        case model, inputTokens = "input_tokens", outputTokens = "output_tokens"
        case costUSD = "cost_usd", promptVersion = "prompt_version", createdAt = "created_at"
    }

    // Parsed helpers
    public var parsedRedFlags: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(redFlags.utf8))) ?? []
    }
    public var parsedHighlights: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(highlights.utf8))) ?? []
    }
    public var parsedAccomplishments: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(accomplishments.utf8))) ?? []
    }
    public var parsedTactics: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(tactics.utf8))) ?? []
    }
    public var parsedActiveHours: [String: Int] {
        (try? JSONDecoder().decode([String: Int].self, from: Data(activeHoursJSON.utf8))) ?? [:]
    }
    public var periodFromDate: Date { Date(timeIntervalSince1970: periodFrom) }
    public var periodToDate: Date { Date(timeIntervalSince1970: periodTo) }

    public var hasRedFlags: Bool {
        !parsedRedFlags.isEmpty
    }

    public var isInsufficientData: Bool {
        status == "insufficient_data"
    }

    public var styleEmoji: String {
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

public struct PeopleCardSummary: FetchableRecord, Decodable, Identifiable, Equatable {
    public var id: Int64
    public var periodFrom: Double
    public var periodTo: Double
    public var summary: String
    public var attention: String  // JSON array
    public var tips: String       // JSON array
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var costUSD: Double
    public var promptVersion: Int
    public var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, periodFrom = "period_from", periodTo = "period_to"
        case summary, attention, tips
        case model, inputTokens = "input_tokens", outputTokens = "output_tokens"
        case costUSD = "cost_usd", promptVersion = "prompt_version", createdAt = "created_at"
    }

    public var parsedAttention: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(attention.utf8))) ?? []
    }
    public var parsedTips: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(tips.utf8))) ?? []
    }
}

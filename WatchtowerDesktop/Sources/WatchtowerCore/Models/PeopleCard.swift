import Foundation
import GRDB

package struct PeopleCard: FetchableRecord, Decodable, Identifiable, Equatable {
    package var id: Int64
    package var userID: String
    package var periodFrom: Double
    package var periodTo: Double
    package var messageCount: Int
    package var channelsActive: Int
    package var threadsInitiated: Int
    package var threadsReplied: Int
    package var avgMessageLength: Double
    package var activeHoursJSON: String
    package var volumeChangePct: Double
    package var summary: String
    package var communicationStyle: String
    package var decisionRole: String
    package var redFlags: String      // JSON array
    package var highlights: String    // JSON array
    package var accomplishments: String // JSON array
    package var communicationGuide: String
    package var decisionStyle: String
    package var tactics: String       // JSON array
    package var relationshipContext: String
    package var status: String
    package var model: String
    package var inputTokens: Int
    package var outputTokens: Int
    package var costUSD: Double
    package var promptVersion: Int
    package var createdAt: String

    // Column mapping
    package enum CodingKeys: String, CodingKey {
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
    package var parsedRedFlags: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(redFlags.utf8))) ?? []
    }
    package var parsedHighlights: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(highlights.utf8))) ?? []
    }
    package var parsedAccomplishments: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(accomplishments.utf8))) ?? []
    }
    package var parsedTactics: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(tactics.utf8))) ?? []
    }
    package var parsedActiveHours: [String: Int] {
        (try? JSONDecoder().decode([String: Int].self, from: Data(activeHoursJSON.utf8))) ?? [:]
    }
    package var periodFromDate: Date { Date(timeIntervalSince1970: periodFrom) }
    package var periodToDate: Date { Date(timeIntervalSince1970: periodTo) }

    package var hasRedFlags: Bool {
        !parsedRedFlags.isEmpty
    }

    package var isInsufficientData: Bool {
        status == "insufficient_data"
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

package struct PeopleCardSummary: FetchableRecord, Decodable, Identifiable, Equatable {
    package var id: Int64
    package var periodFrom: Double
    package var periodTo: Double
    package var summary: String
    package var attention: String  // JSON array
    package var tips: String       // JSON array
    package var model: String
    package var inputTokens: Int
    package var outputTokens: Int
    package var costUSD: Double
    package var promptVersion: Int
    package var createdAt: String

    package init(
        id: Int64,
        periodFrom: Double,
        periodTo: Double,
        summary: String,
        attention: String,
        tips: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        costUSD: Double,
        promptVersion: Int,
        createdAt: String
    ) {
        self.id = id
        self.periodFrom = periodFrom
        self.periodTo = periodTo
        self.summary = summary
        self.attention = attention
        self.tips = tips
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.promptVersion = promptVersion
        self.createdAt = createdAt
    }

    package enum CodingKeys: String, CodingKey {
        case id, periodFrom = "period_from", periodTo = "period_to"
        case summary, attention, tips
        case model, inputTokens = "input_tokens", outputTokens = "output_tokens"
        case costUSD = "cost_usd", promptVersion = "prompt_version", createdAt = "created_at"
    }

    package var parsedAttention: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(attention.utf8))) ?? []
    }
    package var parsedTips: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(tips.utf8))) ?? []
    }
}

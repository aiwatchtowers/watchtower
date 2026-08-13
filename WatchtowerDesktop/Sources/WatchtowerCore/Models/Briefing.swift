import Foundation
import GRDB

// MARK: - Section Item Types

package struct AttentionItem: Decodable, Identifiable, Equatable {
    package let id = UUID()
    package let text: String
    package let sourceType: String?
    package let sourceID: String?
    package let priority: String?
    package let reason: String?
    package let suggestTrack: Bool? // swiftlint:disable:this discouraged_optional_boolean
    package let suggestTask: Bool? // swiftlint:disable:this discouraged_optional_boolean

    package enum CodingKeys: String, CodingKey {
        case text
        case sourceType = "source_type"
        case sourceID = "source_id"
        case priority, reason
        case suggestTrack = "suggest_track"
        case suggestTask = "suggest_task"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        sourceType = try container.decodeIfPresent(String.self, forKey: .sourceType)
        priority = try container.decodeIfPresent(String.self, forKey: .priority)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        suggestTrack = try container.decodeIfPresent(Bool.self, forKey: .suggestTrack)
        suggestTask = try container.decodeIfPresent(Bool.self, forKey: .suggestTask)
        // Accept both string and int for source_id
        if let str = try? container.decodeIfPresent(String.self, forKey: .sourceID) {
            sourceID = str
        } else if let num = try? container.decodeIfPresent(Int.self, forKey: .sourceID) {
            sourceID = String(num)
        } else {
            sourceID = nil
        }
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.sourceType == rhs.sourceType
            && lhs.sourceID == rhs.sourceID && lhs.priority == rhs.priority
            && lhs.reason == rhs.reason && lhs.suggestTrack == rhs.suggestTrack
            && lhs.suggestTask == rhs.suggestTask
    }
}

package struct YourDayItem: Decodable, Identifiable, Equatable {
    package let id = UUID()
    package let text: String
    package let trackID: Int?
    package let taskID: Int?
    package let dueDate: String?
    package let priority: String?
    package let status: String?
    package let ownership: String?

    package enum CodingKeys: String, CodingKey {
        case text
        case trackID = "track_id"
        case taskID = "task_id"
        case dueDate = "due_date"
        case priority, status, ownership
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.trackID == rhs.trackID
            && lhs.taskID == rhs.taskID
            && lhs.dueDate == rhs.dueDate && lhs.priority == rhs.priority
            && lhs.status == rhs.status && lhs.ownership == rhs.ownership
    }
}

package struct WhatHappenedItem: Decodable, Identifiable, Equatable {
    package let id = UUID()
    package let text: String
    package let digestID: Int?
    package let channelName: String?
    package let itemType: String?
    package let importance: String?

    package enum CodingKeys: String, CodingKey {
        case text
        case digestID = "digest_id"
        case channelName = "channel_name"
        case itemType = "item_type"
        case importance
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.digestID == rhs.digestID
            && lhs.channelName == rhs.channelName && lhs.itemType == rhs.itemType
            && lhs.importance == rhs.importance
    }
}

package struct TeamPulseItem: Decodable, Identifiable, Equatable {
    package let id = UUID()
    package let text: String
    package let userID: String?
    package let signalType: String?
    package let detail: String?

    package enum CodingKeys: String, CodingKey {
        case text
        case userID = "user_id"
        case signalType = "signal_type"
        case detail
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.userID == rhs.userID
            && lhs.signalType == rhs.signalType && lhs.detail == rhs.detail
    }
}

package struct CoachingItem: Decodable, Identifiable, Equatable {
    package let id = UUID()
    package let text: String
    package let relatedUserID: String?
    package let category: String?

    package enum CodingKeys: String, CodingKey {
        case text
        case relatedUserID = "related_user_id"
        case category
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.relatedUserID == rhs.relatedUserID
            && lhs.category == rhs.category
    }
}

// MARK: - Briefing

package struct Briefing: FetchableRecord, Decodable, Identifiable, Equatable {
    package let id: Int
    package let userID: String
    package let date: String
    package let role: String
    package let attention: String
    package let yourDay: String
    package let whatHappened: String
    package let teamPulse: String
    package let coaching: String
    package let model: String
    package let inputTokens: Int
    package let outputTokens: Int
    package let costUSD: Double
    package let promptVersion: Int
    package let readAt: String?
    package let createdAt: String

    package enum CodingKeys: String, CodingKey {
        case id, date, role, attention, coaching, model
        case userID = "user_id"
        case yourDay = "your_day"
        case whatHappened = "what_happened"
        case teamPulse = "team_pulse"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUSD = "cost_usd"
        case promptVersion = "prompt_version"
        case readAt = "read_at"
        case createdAt = "created_at"
    }

    package var isRead: Bool { readAt != nil }

    private static let decoder = JSONDecoder()

    package var parsedAttention: [AttentionItem] {
        guard let data = attention.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([AttentionItem].self, from: data)) ?? []
    }

    package var parsedYourDay: [YourDayItem] {
        guard let data = yourDay.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([YourDayItem].self, from: data)) ?? []
    }

    package var parsedWhatHappened: [WhatHappenedItem] {
        guard let data = whatHappened.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([WhatHappenedItem].self, from: data)) ?? []
    }

    package var parsedTeamPulse: [TeamPulseItem] {
        guard let data = teamPulse.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([TeamPulseItem].self, from: data)) ?? []
    }

    package var parsedCoaching: [CoachingItem] {
        guard let data = coaching.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([CoachingItem].self, from: data)) ?? []
    }

    package var dateLabel: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        // Parse YYYY-MM-DD
        let isoFmt = DateFormatter()
        isoFmt.dateFormat = "yyyy-MM-dd"
        if let parsed = isoFmt.date(from: date) {
            return formatter.string(from: parsed)
        }
        return date
    }
}

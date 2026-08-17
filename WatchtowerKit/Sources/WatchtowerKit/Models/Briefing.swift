import Foundation
import GRDB

// MARK: - Section Item Types

public struct AttentionItem: Decodable, Identifiable, Equatable {
    public let id = UUID()
    public let text: String
    public let sourceType: String?
    public let sourceID: String?
    public let priority: String?
    public let reason: String?
    public let suggestTrack: Bool? // swiftlint:disable:this discouraged_optional_boolean
    public let suggestTask: Bool? // swiftlint:disable:this discouraged_optional_boolean

    public enum CodingKeys: String, CodingKey {
        case text
        case sourceType = "source_type"
        case sourceID = "source_id"
        case priority, reason
        case suggestTrack = "suggest_track"
        case suggestTask = "suggest_task"
    }

    public init(from decoder: Decoder) throws {
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

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.sourceType == rhs.sourceType
            && lhs.sourceID == rhs.sourceID && lhs.priority == rhs.priority
            && lhs.reason == rhs.reason && lhs.suggestTrack == rhs.suggestTrack
            && lhs.suggestTask == rhs.suggestTask
    }
}

public struct YourDayItem: Decodable, Identifiable, Equatable {
    public let id = UUID()
    public let text: String
    public let trackID: Int?
    public let taskID: Int?
    public let dueDate: String?
    public let priority: String?
    public let status: String?
    public let ownership: String?

    public enum CodingKeys: String, CodingKey {
        case text
        case trackID = "track_id"
        case taskID = "task_id"
        case dueDate = "due_date"
        case priority, status, ownership
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.trackID == rhs.trackID
            && lhs.taskID == rhs.taskID
            && lhs.dueDate == rhs.dueDate && lhs.priority == rhs.priority
            && lhs.status == rhs.status && lhs.ownership == rhs.ownership
    }
}

public struct WhatHappenedItem: Decodable, Identifiable, Equatable {
    public let id = UUID()
    public let text: String
    public let digestID: Int?
    public let channelName: String?
    public let itemType: String?
    public let importance: String?

    public enum CodingKeys: String, CodingKey {
        case text
        case digestID = "digest_id"
        case channelName = "channel_name"
        case itemType = "item_type"
        case importance
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.digestID == rhs.digestID
            && lhs.channelName == rhs.channelName && lhs.itemType == rhs.itemType
            && lhs.importance == rhs.importance
    }
}

public struct TeamPulseItem: Decodable, Identifiable, Equatable {
    public let id = UUID()
    public let text: String
    public let userID: String?
    public let signalType: String?
    public let detail: String?

    public enum CodingKeys: String, CodingKey {
        case text
        case userID = "user_id"
        case signalType = "signal_type"
        case detail
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.userID == rhs.userID
            && lhs.signalType == rhs.signalType && lhs.detail == rhs.detail
    }
}

public struct CoachingItem: Decodable, Identifiable, Equatable {
    public let id = UUID()
    public let text: String
    public let relatedUserID: String?
    public let category: String?

    public enum CodingKeys: String, CodingKey {
        case text
        case relatedUserID = "related_user_id"
        case category
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.relatedUserID == rhs.relatedUserID
            && lhs.category == rhs.category
    }
}

// MARK: - Briefing

public struct Briefing: FetchableRecord, Decodable, Identifiable, Equatable {
    public let id: Int
    public let userID: String
    public let date: String
    public let role: String
    public let attention: String
    public let yourDay: String
    public let whatHappened: String
    public let teamPulse: String
    public let coaching: String
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let costUSD: Double
    public let promptVersion: Int
    public let readAt: String?
    public let createdAt: String

    public enum CodingKeys: String, CodingKey {
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

    public var isRead: Bool { readAt != nil }

    private static let decoder = JSONDecoder()

    public var parsedAttention: [AttentionItem] {
        guard let data = attention.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([AttentionItem].self, from: data)) ?? []
    }

    public var parsedYourDay: [YourDayItem] {
        guard let data = yourDay.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([YourDayItem].self, from: data)) ?? []
    }

    public var parsedWhatHappened: [WhatHappenedItem] {
        guard let data = whatHappened.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([WhatHappenedItem].self, from: data)) ?? []
    }

    public var parsedTeamPulse: [TeamPulseItem] {
        guard let data = teamPulse.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([TeamPulseItem].self, from: data)) ?? []
    }

    public var parsedCoaching: [CoachingItem] {
        guard let data = coaching.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([CoachingItem].self, from: data)) ?? []
    }

    public var dateLabel: String {
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

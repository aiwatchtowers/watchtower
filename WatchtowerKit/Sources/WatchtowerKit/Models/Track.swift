import Foundation
import GRDB

// MARK: - Track v2 Supporting Types

public struct TrackParticipant: Codable, Identifiable, Equatable {
    public let id = UUID()
    public let name: String
    public let userID: String?
    public let stance: String?

    enum CodingKeys: String, CodingKey {
        case name
        case userID = "user_id"
        case stance
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.userID == rhs.userID && lhs.stance == rhs.stance
    }
}

public struct TrackSourceRef: Codable, Identifiable, Equatable {
    public let ts: String
    public let channelID: String?
    public let threadTS: String?
    public let author: String
    public let text: String

    public var id: String { "\(ts)-\(author)" }

    enum CodingKeys: String, CodingKey {
        case ts
        case channelID = "channel_id"
        case threadTS = "thread_ts"
        case author
        case text
    }
}

public struct TrackDecisionOption: Codable, Identifiable, Equatable {
    public let option: String
    public let supporters: [String]
    public let pros: String
    public let cons: String

    public var id: String { option }

    enum CodingKeys: String, CodingKey {
        case option, supporters, pros, cons
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        option = try container.decodeIfPresent(String.self, forKey: .option) ?? ""
        supporters = try container.decodeIfPresent([String].self, forKey: .supporters) ?? []
        pros = try container.decodeIfPresent(String.self, forKey: .pros) ?? ""
        cons = try container.decodeIfPresent(String.self, forKey: .cons) ?? ""
    }
}

public struct TrackSubItem: Codable, Identifiable, Equatable {
    public let text: String
    public var status: String // "open" or "done"

    public var id: String { text }
    public var isDone: Bool { status == "done" }
}

// MARK: - Track

public struct Track: FetchableRecord, Identifiable, Equatable {
    public let id: Int
    public let assigneeUserID: String
    public let text: String
    public let context: String
    public let category: String
    public let ownership: String
    public let ballOn: String
    public let ownerUserID: String
    public let requesterName: String
    public let requesterUserID: String
    public let blocking: String
    public let decisionSummary: String
    public let decisionOptions: String
    public let subItems: String
    public let participants: String
    public let sourceRefs: String
    public let tags: String
    public let channelIDs: String
    public let relatedDigestIDs: String
    public let priority: String
    public let dueDate: Double?
    public let fingerprint: String
    public let readAt: String?
    public let hasUpdates: Bool
    public let dismissedAt: String
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let costUSD: Double
    public let promptVersion: Int
    public let createdAt: String
    public let updatedAt: String
    public let origin: String
    public let instruction: String
    public let enabled: Bool
    public let lastRunAt: String
    public let linkedTargetID: Int?

    public init(row: Row) {
        id = row["id"]
        assigneeUserID = row["assignee_user_id"] ?? ""
        text = row["text"] ?? ""
        context = row["context"] ?? ""
        category = row["category"] ?? "task"
        ownership = row["ownership"] ?? "mine"
        ballOn = row["ball_on"] ?? ""
        ownerUserID = row["owner_user_id"] ?? ""
        requesterName = row["requester_name"] ?? ""
        requesterUserID = row["requester_user_id"] ?? ""
        blocking = row["blocking"] ?? ""
        decisionSummary = row["decision_summary"] ?? ""
        decisionOptions = row["decision_options"] ?? "[]"
        subItems = row["sub_items"] ?? "[]"
        participants = row["participants"] ?? "[]"
        sourceRefs = row["source_refs"] ?? "[]"
        tags = row["tags"] ?? "[]"
        channelIDs = row["channel_ids"] ?? "[]"
        relatedDigestIDs = row["related_digest_ids"] ?? "[]"
        priority = row["priority"] ?? "medium"
        dueDate = row["due_date"]
        fingerprint = row["fingerprint"] ?? "[]"
        readAt = row["read_at"]
        hasUpdates = row["has_updates"] ?? false
        dismissedAt = row["dismissed_at"] ?? ""
        model = row["model"] ?? ""
        inputTokens = row["input_tokens"] ?? 0
        outputTokens = row["output_tokens"] ?? 0
        costUSD = row["cost_usd"] ?? 0
        promptVersion = row["prompt_version"] ?? 0
        createdAt = row["created_at"] ?? ""
        updatedAt = row["updated_at"] ?? ""
        origin = row["origin"] ?? "auto"
        instruction = row["instruction"] ?? ""
        enabled = row["enabled"] ?? true
        lastRunAt = row["last_run_at"] ?? ""
        linkedTargetID = row["linked_target_id"]
    }

    // MARK: - Ownership predicates

    public var isMine: Bool { ownership == "mine" }
    public var isDelegated: Bool { ownership == "delegated" }
    public var isWatching: Bool { ownership == "watching" }

    // MARK: - Origin

    public var isCustom: Bool { origin == "custom" }

    // MARK: - Read predicates

    public var isRead: Bool { readAt != nil && !hasUpdates }
    public var isUnread: Bool { !isRead }
    public var isDismissed: Bool { !dismissedAt.isEmpty }

    // MARK: - Labels

    public var categoryLabel: String {
        switch category {
        case "task": return "Task"
        case "decision": return "Decision"
        case "risk": return "Risk"
        case "blocker": return "Blocker"
        case "fyi": return "FYI"
        case "question": return "Question"
        case "project": return "Project"
        default: return category.capitalized
        }
    }

    public var ownershipLabel: String {
        switch ownership {
        case "mine": return "Mine"
        case "delegated": return "Delegated"
        case "watching": return "Watching"
        default: return ownership.capitalized
        }
    }

    // MARK: - Date helpers

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    private static let iso8601Standard: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    public var createdDate: Date {
        if let date = Self.iso8601WithFractional.date(from: createdAt) { return date }
        return Self.iso8601Standard.date(from: createdAt) ?? Date()
    }

    public var updatedDate: Date {
        if let date = Self.iso8601WithFractional.date(from: updatedAt) { return date }
        return Self.iso8601Standard.date(from: updatedAt) ?? Date()
    }

    public var updatedAgo: String {
        let interval = Date().timeIntervalSince(updatedDate)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        let days = Int(interval / 86400)
        return days == 1 ? "1d ago" : "\(days)d ago"
    }

    public var dueDateFormatted: String? {
        guard let dueDate else { return nil }
        let date = Date(timeIntervalSince1970: dueDate)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    public var isOverdue: Bool {
        guard let dueDate else { return false }
        return Date(timeIntervalSince1970: dueDate) < Date()
    }

    // MARK: - JSON decoders

    public var decodedParticipants: [TrackParticipant] {
        guard !participants.isEmpty, participants != "[]",
              let data = participants.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([TrackParticipant].self, from: data)) ?? []
    }

    public var decodedSourceRefs: [TrackSourceRef] {
        guard !sourceRefs.isEmpty, sourceRefs != "[]",
              let data = sourceRefs.data(using: .utf8) else { return [] }
        let refs = (try? JSONDecoder().decode([TrackSourceRef].self, from: data)) ?? []
        return refs.filter { !$0.ts.isEmpty }
    }

    public var decodedTags: [String] {
        guard !tags.isEmpty, tags != "[]",
              let data = tags.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    public var decodedChannelIDs: [String] {
        guard !channelIDs.isEmpty, channelIDs != "[]",
              let data = channelIDs.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    public var decodedRelatedDigestIDs: [Int] {
        guard !relatedDigestIDs.isEmpty, relatedDigestIDs != "[]",
              let data = relatedDigestIDs.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Int].self, from: data)) ?? []
    }

    public var decodedDecisionOptions: [TrackDecisionOption] {
        guard !decisionOptions.isEmpty, decisionOptions != "[]",
              let data = decisionOptions.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([TrackDecisionOption].self, from: data)) ?? []
    }

    public var decodedSubItems: [TrackSubItem] {
        guard !subItems.isEmpty, subItems != "[]",
              let data = subItems.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([TrackSubItem].self, from: data)) ?? []
    }

    public var subItemsProgress: (done: Int, total: Int) {
        let items = decodedSubItems
        let done = items.filter(\.isDone).count
        return (done, items.count)
    }

    // MARK: - Priority helpers

    public var priorityOrder: Int {
        switch priority {
        case "high": return 0
        case "medium": return 1
        case "low": return 2
        default: return 1
        }
    }
}

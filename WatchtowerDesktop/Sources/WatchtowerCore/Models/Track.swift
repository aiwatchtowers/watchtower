import Foundation
import GRDB

// MARK: - Track v2 Supporting Types

package struct TrackParticipant: Codable, Identifiable, Equatable {
    package let id = UUID()
    package let name: String
    package let userID: String?
    package let stance: String?

    package enum CodingKeys: String, CodingKey {
        case name
        case userID = "user_id"
        case stance
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.userID == rhs.userID && lhs.stance == rhs.stance
    }
}

package struct TrackSourceRef: Codable, Identifiable, Equatable {
    package let ts: String
    package let channelID: String?
    package let threadTS: String?
    package let author: String
    package let text: String

    package var id: String { "\(ts)-\(author)" }

    package enum CodingKeys: String, CodingKey {
        case ts
        case channelID = "channel_id"
        case threadTS = "thread_ts"
        case author
        case text
    }
}

package struct TrackDecisionOption: Codable, Identifiable, Equatable {
    package let option: String
    package let supporters: [String]
    package let pros: String
    package let cons: String

    package var id: String { option }

    package enum CodingKeys: String, CodingKey {
        case option, supporters, pros, cons
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        option = try container.decodeIfPresent(String.self, forKey: .option) ?? ""
        supporters = try container.decodeIfPresent([String].self, forKey: .supporters) ?? []
        pros = try container.decodeIfPresent(String.self, forKey: .pros) ?? ""
        cons = try container.decodeIfPresent(String.self, forKey: .cons) ?? ""
    }
}

package struct TrackSubItem: Codable, Identifiable, Equatable {
    package let text: String
    package var status: String // "open" or "done"

    package init(text: String, status: String) {
        self.text = text
        self.status = status
    }

    package var id: String { text }
    package var isDone: Bool { status == "done" }
}

// MARK: - Track

package struct Track: FetchableRecord, Identifiable, Equatable {
    package let id: Int
    package let assigneeUserID: String
    package let text: String
    package let context: String
    package let category: String
    package let ownership: String
    package let ballOn: String
    package let ownerUserID: String
    package let requesterName: String
    package let requesterUserID: String
    package let blocking: String
    package let decisionSummary: String
    package let decisionOptions: String
    package let subItems: String
    package let participants: String
    package let sourceRefs: String
    package let tags: String
    package let channelIDs: String
    package let relatedDigestIDs: String
    package let priority: String
    package let dueDate: Double?
    package let fingerprint: String
    package let readAt: String?
    package let hasUpdates: Bool
    package let dismissedAt: String
    package let model: String
    package let inputTokens: Int
    package let outputTokens: Int
    package let costUSD: Double
    package let promptVersion: Int
    package let createdAt: String
    package let updatedAt: String
    package let origin: String
    package let instruction: String
    package let enabled: Bool
    package let lastRunAt: String
    package let linkedTargetID: Int?

    package init(row: Row) {
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

    package var isMine: Bool { ownership == "mine" }
    package var isDelegated: Bool { ownership == "delegated" }
    package var isWatching: Bool { ownership == "watching" }

    // MARK: - Origin

    package var isCustom: Bool { origin == "custom" }

    // MARK: - Read predicates

    package var isRead: Bool { readAt != nil && !hasUpdates }
    package var isUnread: Bool { !isRead }
    package var isDismissed: Bool { !dismissedAt.isEmpty }

    // MARK: - Labels

    package var categoryLabel: String {
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

    package var ownershipLabel: String {
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

    package var createdDate: Date {
        if let date = Self.iso8601WithFractional.date(from: createdAt) { return date }
        return Self.iso8601Standard.date(from: createdAt) ?? Date()
    }

    package var updatedDate: Date {
        if let date = Self.iso8601WithFractional.date(from: updatedAt) { return date }
        return Self.iso8601Standard.date(from: updatedAt) ?? Date()
    }

    package var updatedAgo: String {
        let interval = Date().timeIntervalSince(updatedDate)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        let days = Int(interval / 86400)
        return days == 1 ? "1d ago" : "\(days)d ago"
    }

    package var dueDateFormatted: String? {
        guard let dueDate else { return nil }
        let date = Date(timeIntervalSince1970: dueDate)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    package var isOverdue: Bool {
        guard let dueDate else { return false }
        return Date(timeIntervalSince1970: dueDate) < Date()
    }

    // MARK: - JSON decoders

    package var decodedParticipants: [TrackParticipant] {
        guard !participants.isEmpty, participants != "[]",
              let data = participants.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([TrackParticipant].self, from: data)) ?? []
    }

    package var decodedSourceRefs: [TrackSourceRef] {
        guard !sourceRefs.isEmpty, sourceRefs != "[]",
              let data = sourceRefs.data(using: .utf8) else { return [] }
        let refs = (try? JSONDecoder().decode([TrackSourceRef].self, from: data)) ?? []
        return refs.filter { !$0.ts.isEmpty }
    }

    package var decodedTags: [String] {
        guard !tags.isEmpty, tags != "[]",
              let data = tags.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    package var decodedChannelIDs: [String] {
        guard !channelIDs.isEmpty, channelIDs != "[]",
              let data = channelIDs.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    package var decodedRelatedDigestIDs: [Int] {
        guard !relatedDigestIDs.isEmpty, relatedDigestIDs != "[]",
              let data = relatedDigestIDs.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Int].self, from: data)) ?? []
    }

    package var decodedDecisionOptions: [TrackDecisionOption] {
        guard !decisionOptions.isEmpty, decisionOptions != "[]",
              let data = decisionOptions.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([TrackDecisionOption].self, from: data)) ?? []
    }

    package var decodedSubItems: [TrackSubItem] {
        guard !subItems.isEmpty, subItems != "[]",
              let data = subItems.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([TrackSubItem].self, from: data)) ?? []
    }

    package var subItemsProgress: (done: Int, total: Int) {
        let items = decodedSubItems
        let done = items.filter(\.isDone).count
        return (done, items.count)
    }

    // MARK: - Priority helpers

    package var priorityOrder: Int {
        switch priority {
        case "high": return 0
        case "medium": return 1
        case "low": return 2
        default: return 1
        }
    }
}

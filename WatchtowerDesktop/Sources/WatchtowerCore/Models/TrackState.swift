import Foundation
import GRDB
import WatchtowerKit

// TrackState is a snapshot of a track's narrative fields at a point in time,
// captured BEFORE a mutating call (extraction or manual edit) overwrites
// those fields. See docs/inventory/tracks.md TRACKS-06.
package struct TrackState: FetchableRecord, Identifiable, Equatable {
    package let id: Int
    package let trackID: Int
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
    package let tags: String
    package let priority: String
    package let dueDate: Double?
    package let source: String   // 'extraction' | 'manual'
    package let model: String
    package let promptVersion: Int
    package let createdAt: String

    package init(row: Row) {
        id = row["id"]
        trackID = row["track_id"]
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
        tags = row["tags"] ?? "[]"
        priority = row["priority"] ?? "medium"
        dueDate = row["due_date"]
        source = row["source"] ?? "extraction"
        model = row["model"] ?? ""
        promptVersion = row["prompt_version"] ?? 0
        createdAt = row["created_at"] ?? ""
    }

    // MARK: - Source helpers

    package var isExtraction: Bool { source == "extraction" }
    package var isManual: Bool { source == "manual" }

    package var sourceLabel: String {
        switch source {
        case "extraction":
            return model.isEmpty ? "AI extraction" : "AI extraction (\(model))"
        case "manual": return "Manual edit"
        default: return source.capitalized
        }
    }

    // MARK: - Date

    private static let iso8601: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    package var createdDate: Date {
        Self.iso8601.date(from: createdAt) ?? Date()
    }

    package var createdAgo: String {
        let interval = Date().timeIntervalSince(createdDate)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        let days = Int(interval / 86400)
        return days == 1 ? "1d ago" : "\(days)d ago"
    }

    // MARK: - JSON decoders (mirror Track)

    package var decodedSubItems: [TrackSubItem] {
        guard !subItems.isEmpty, subItems != "[]",
              let data = subItems.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([TrackSubItem].self, from: data)) ?? []
    }

    package var decodedTags: [String] {
        guard !tags.isEmpty, tags != "[]",
              let data = tags.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}

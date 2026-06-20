import Foundation
import GRDB

// MARK: - Catch-Up v2 review-mode models
//
// These mirror the Go `catchup_sessions` / `catchup_themes` rows (see
// internal/db/catchup_store.go). A session is one backlog review run; themes
// are cross-source clusters reviewed one at a time.

/// One snapshot reference driving a theme's acknowledge cascade. Mirrors the Go
/// `CatchupRef` ({area,id,label}); `id` decodes from the JSON key `id`.
struct CatchUpRef: Codable, Identifiable, Equatable {
    let area: String
    let id: Int
    let label: String

    /// Stable identity for SwiftUI lists: the row `id` is per-table autoincrement,
    /// so two refs in different areas can share it — key by area+id instead.
    var compositeID: String { "\(area):\(id)" }

    enum CodingKeys: String, CodingKey {
        case area, id, label
    }

    init(area: String, id: Int, label: String) {
        self.area = area
        self.id = id
        self.label = label
    }

    // Tolerate missing fields from older payloads / partial model output.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        area = try container.decodeIfPresent(String.self, forKey: .area) ?? ""
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
    }
}

/// One Catch-Up review run.
struct CatchUpSession: FetchableRecord, Identifiable, Equatable {
    let id: Int
    let createdAt: String
    let status: String
    let totalThemes: Int
    let reviewedCount: Int

    init(row: Row) {
        id = row["id"]
        createdAt = row["created_at"] ?? ""
        status = row["status"] ?? ""
        totalThemes = row["total_themes"] ?? 0
        reviewedCount = row["reviewed_count"] ?? 0
    }

    // MARK: - Status predicates

    var isActive: Bool { status == "active" }
    var isBuilding: Bool { status == "building" }
}

/// One cross-source theme within a session, persisted incrementally as fan-out
/// expansion completes.
struct CatchUpTheme: FetchableRecord, Identifiable, Equatable {
    let id: Int
    let sessionID: Int
    let orderIdx: Int
    let title: String
    let narrative: String
    let priority: String
    let needsYou: Bool
    let suggestedAction: String
    let refs: String
    let genState: String
    let reviewState: String
    let snoozeUntil: String
    let taskID: Int
    let createdAt: String
    let updatedAt: String

    init(row: Row) {
        id = row["id"]
        sessionID = row["session_id"]
        orderIdx = row["order_idx"] ?? 0
        title = row["title"] ?? ""
        narrative = row["narrative"] ?? ""
        priority = row["priority"] ?? "medium"
        needsYou = row["needs_you"] ?? false
        suggestedAction = row["suggested_action"] ?? ""
        refs = row["refs"] ?? "[]"
        genState = row["gen_state"] ?? "skeleton"
        reviewState = row["review_state"] ?? "pending"
        snoozeUntil = row["snooze_until"] ?? ""
        taskID = row["task_id"] ?? 0
        createdAt = row["created_at"] ?? ""
        updatedAt = row["updated_at"] ?? ""
    }

    // MARK: - Generation / review predicates

    var isReady: Bool { genState == "ready" }
    var isExpanding: Bool { genState == "skeleton" || genState == "expanding" }
    var isFailed: Bool { genState == "failed" }
    var isPending: Bool { reviewState == "pending" }
    var isReviewed: Bool { reviewState == "reviewed" }
    var isSnoozed: Bool { reviewState == "snoozed" }

    // MARK: - JSON refs

    /// Parsed snapshot refs (pattern from `Track.decodedSourceRefs`).
    var decodedRefs: [CatchUpRef] {
        guard !refs.isEmpty, refs != "[]",
              let data = refs.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CatchUpRef].self, from: data)) ?? []
    }

    // MARK: - Priority helpers

    var priorityOrder: Int {
        switch priority {
        case "high": return 0
        case "medium": return 1
        case "low": return 2
        default: return 1
        }
    }
}

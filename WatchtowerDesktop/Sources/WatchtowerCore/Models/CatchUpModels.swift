import Foundation
import GRDB

// MARK: - Catch-Up v2 review-mode models
//
// These mirror the Go `catchup_sessions` / `catchup_themes` rows (see
// internal/db/catchup_store.go). A session is one backlog review run; themes
// are cross-source clusters reviewed one at a time.

/// One snapshot reference driving a theme's acknowledge cascade. Mirrors the Go
/// `CatchupRef` ({area,id,label}); `id` decodes from the JSON key `id`.
package struct CatchUpRef: Codable, Identifiable, Equatable {
    package let area: String
    package let id: Int
    package let label: String

    /// Stable identity for SwiftUI lists: the row `id` is per-table autoincrement,
    /// so two refs in different areas can share it — key by area+id instead.
    package var compositeID: String { "\(area):\(id)" }

    package enum CodingKeys: String, CodingKey {
        case area, id, label
    }

    package init(area: String, id: Int, label: String) {
        self.area = area
        self.id = id
        self.label = label
    }

    // Tolerate missing fields from older payloads / partial model output.
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        area = try container.decodeIfPresent(String.self, forKey: .area) ?? ""
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
    }
}

/// One Catch-Up review run.
package struct CatchUpSession: FetchableRecord, Identifiable, Equatable {
    package let id: Int
    package let createdAt: String
    package let status: String
    package let totalThemes: Int
    package let reviewedCount: Int

    package init(row: Row) {
        id = row["id"]
        createdAt = row["created_at"] ?? ""
        status = row["status"] ?? ""
        totalThemes = row["total_themes"] ?? 0
        reviewedCount = row["reviewed_count"] ?? 0
    }

    // MARK: - Status predicates

    package var isActive: Bool { status == "active" }
    package var isBuilding: Bool { status == "building" }
}

/// One cross-source theme within a session, persisted incrementally as fan-out
/// expansion completes.
package struct CatchUpTheme: FetchableRecord, Identifiable, Equatable {
    package let id: Int
    package let sessionID: Int
    package let orderIdx: Int
    package let title: String
    package let narrative: String
    package let priority: String
    package let needsYou: Bool
    package let suggestedAction: String
    package let refs: String
    package let genState: String
    package let reviewState: String
    package let snoozeUntil: String
    package let taskID: Int
    package let createdAt: String
    package let updatedAt: String

    package init(row: Row) {
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

    package var isReady: Bool { genState == "ready" }
    package var isExpanding: Bool { genState == "skeleton" || genState == "expanding" }
    package var isFailed: Bool { genState == "failed" }
    package var isPending: Bool { reviewState == "pending" }
    package var isReviewed: Bool { reviewState == "reviewed" }
    package var isSnoozed: Bool { reviewState == "snoozed" }

    // MARK: - JSON refs

    /// Parsed snapshot refs (pattern from `Track.decodedSourceRefs`).
    package var decodedRefs: [CatchUpRef] {
        guard !refs.isEmpty, refs != "[]",
              let data = refs.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CatchUpRef].self, from: data)) ?? []
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

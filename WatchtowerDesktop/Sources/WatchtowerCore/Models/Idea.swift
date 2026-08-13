import Foundation
import GRDB

// MARK: - Idea

/// A durable, dedupable idea/decision/note mined from Slack digests, meeting
/// transcripts, Gmail, and Jira, plus owner-authored ones from chat — see
/// `internal/db/ideas.go` on the Go side (table `ideas`).
package struct Idea: FetchableRecord, Identifiable, Equatable {
    package let id: Int
    package let kindRaw: String       // column: kind
    package let title: String
    package let essence: String
    package let statusRaw: String     // column: status
    package let source: String
    package let snoozeUntil: String   // column: snooze_until
    package let needsReview: Bool     // column: needs_review
    package let reviewReason: String  // column: review_reason
    package let similarToID: Int?         // column: similar_to_id
    package let mergedIntoID: Int?        // column: merged_into_id
    package let supersededByID: Int?      // column: superseded_by_id
    package let convertedTargetID: Int?   // column: converted_target_id
    package let ownerRating: Int      // column: owner_rating
    package let ratingComment: String // column: rating_comment
    package let lastMentionAt: String // column: last_mention_at
    package let createdAt: String     // column: created_at
    package let updatedAt: String     // column: updated_at
    package let seenAt: String?       // column: seen_at

    package enum Kind: String {
        case idea
        case decision
        case note
    }

    package enum Status: String {
        case proposed
        case active
        case rejected
        case notNow = "not_now"
        case converted
        case dropped
        case merged
        case superseded
        case reversed
    }

    /// Typed kind derived from the `kind` column.
    package var kind: Kind {
        Kind(rawValue: kindRaw) ?? .idea
    }

    /// Typed status derived from the `status` column.
    package var status: Status {
        Status(rawValue: statusRaw) ?? .proposed
    }

    /// True when this idea belongs in the review queue: freshly proposed, or
    /// explicitly flagged for a second look (e.g. an ambiguous merge candidate).
    package var isForReview: Bool {
        status == .proposed || needsReview
    }

    package init(row: Row) {
        id = row["id"]
        kindRaw = row["kind"] ?? "idea"
        title = row["title"] ?? ""
        essence = row["essence"] ?? ""
        statusRaw = row["status"] ?? "proposed"
        source = row["source"] ?? "mined"
        snoozeUntil = row["snooze_until"] ?? ""
        needsReview = row["needs_review"] ?? false
        reviewReason = row["review_reason"] ?? ""
        similarToID = row["similar_to_id"] as Int?
        mergedIntoID = row["merged_into_id"] as Int?
        supersededByID = row["superseded_by_id"] as Int?
        convertedTargetID = row["converted_target_id"] as Int?
        ownerRating = row["owner_rating"] ?? 0
        ratingComment = row["rating_comment"] ?? ""
        lastMentionAt = row["last_mention_at"] ?? ""
        createdAt = row["created_at"] ?? ""
        updatedAt = row["updated_at"] ?? ""
        seenAt = row["seen_at"] as String?
    }
}

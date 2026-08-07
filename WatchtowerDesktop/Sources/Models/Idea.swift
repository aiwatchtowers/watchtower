import Foundation
import GRDB

// MARK: - Idea

/// A durable, dedupable idea/decision/note mined from Slack digests, meeting
/// transcripts, Gmail, and Jira, plus owner-authored ones from chat — see
/// `internal/db/ideas.go` on the Go side (table `ideas`).
struct Idea: FetchableRecord, Identifiable, Equatable {
    let id: Int
    let kindRaw: String       // column: kind
    let title: String
    let essence: String
    let statusRaw: String     // column: status
    let source: String
    let snoozeUntil: String   // column: snooze_until
    let needsReview: Bool     // column: needs_review
    let reviewReason: String  // column: review_reason
    let similarToID: Int?         // column: similar_to_id
    let mergedIntoID: Int?        // column: merged_into_id
    let supersededByID: Int?      // column: superseded_by_id
    let convertedTargetID: Int?   // column: converted_target_id
    let ownerRating: Int      // column: owner_rating
    let ratingComment: String // column: rating_comment
    let lastMentionAt: String // column: last_mention_at
    let createdAt: String     // column: created_at
    let updatedAt: String     // column: updated_at

    enum Kind: String {
        case idea
        case decision
        case note
    }

    enum Status: String {
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
    var kind: Kind {
        Kind(rawValue: kindRaw) ?? .idea
    }

    /// Typed status derived from the `status` column.
    var status: Status {
        Status(rawValue: statusRaw) ?? .proposed
    }

    /// True when this idea belongs in the review queue: freshly proposed, or
    /// explicitly flagged for a second look (e.g. an ambiguous merge candidate).
    var isForReview: Bool {
        status == .proposed || needsReview
    }

    init(row: Row) {
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
    }
}

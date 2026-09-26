import Foundation
import GRDB

// MARK: - IdeaMention

/// A single sighting of an idea across sources — an idea accumulates one
/// mention row per occurrence instead of being overwritten. See
/// `internal/db/ideas.go` on the Go side (table `idea_mentions`).
package struct IdeaMention: FetchableRecord, Identifiable, Equatable {
    package let id: Int
    package let ideaID: Int    // column: idea_id
    package let source: String
    package let ref: String
    package let quote: String
    package let author: String
    package let saidAt: String     // column: said_at
    package let createdAt: String  // column: created_at

    package enum Source: String {
        case slack
        case meeting
        case gmail
        case jira
        case owner
    }

    /// Typed source derived from the `source` column.
    package var sourceKind: Source {
        Source(rawValue: source) ?? .owner
    }

    package init(row: Row) {
        id = row["id"]
        ideaID = row["idea_id"]
        source = row["source"] ?? "owner"
        ref = row["ref"] ?? ""
        quote = row["quote"] ?? ""
        author = row["author"] ?? ""
        saidAt = row["said_at"] ?? ""
        createdAt = row["created_at"] ?? ""
    }
}

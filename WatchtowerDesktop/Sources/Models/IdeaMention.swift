import Foundation
import GRDB

// MARK: - IdeaMention

/// A single sighting of an idea across sources — an idea accumulates one
/// mention row per occurrence instead of being overwritten. See
/// `internal/db/ideas.go` on the Go side (table `idea_mentions`).
struct IdeaMention: FetchableRecord, Identifiable, Equatable {
    let id: Int
    let ideaID: Int    // column: idea_id
    let source: String
    let ref: String
    let quote: String
    let author: String
    let saidAt: String     // column: said_at
    let createdAt: String  // column: created_at

    enum Source: String {
        case slack
        case meeting
        case gmail
        case jira
        case owner
    }

    /// Typed source derived from the `source` column.
    var sourceKind: Source {
        Source(rawValue: source) ?? .owner
    }

    init(row: Row) {
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

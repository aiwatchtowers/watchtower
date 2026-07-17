import Foundation
import GRDB

// MARK: - Secretary memory vault models
//
// These mirror the Go memory index rows (see internal/db/memory.go): the
// SQLite side is a rebuildable mirror of the markdown vault (MEM-02), so
// everything here is read-side. File bodies come from the vault directory,
// not from these rows.

/// One `memory_nodes` row as shown in the browser list, joined with the
/// dispute side table. Tombstones are filtered out at query level.
struct MemoryNodeListItem: FetchableRecord, Identifiable, Equatable {
    let id: String
    let type: String // entity | episode | rollup | belief
    let tier: String // short | long
    let status: String // active | closed | shaken | retired
    let title: String
    let path: String // vault-relative file path
    let indexedAt: String
    let subject: String // belief subject entity id, "" otherwise
    let confidence: Double // belief confidence 0..1, 0 otherwise
    let disputeReason: String? // non-nil when a dispute flag is pending

    init(row: Row) {
        id = row["id"]
        type = row["type"] ?? ""
        tier = row["tier"] ?? ""
        status = row["status"] ?? ""
        title = row["title"] ?? ""
        path = row["path"] ?? ""
        indexedAt = row["indexed_at"] ?? ""
        subject = row["subject"] ?? ""
        confidence = row["confidence"] ?? 0
        disputeReason = row["dispute_reason"]
    }

    var isBelief: Bool { type == "belief" }
    var isDisputed: Bool { disputeReason != nil }

    /// Falls back to the id for nodes whose body has no H1 yet.
    var displayTitle: String { title.isEmpty ? id : title }
}

/// One FTS hit (mirrors Go `SearchMemoryFTS`): node identity plus a snippet
/// of the matched body region.
struct MemorySearchHit: FetchableRecord, Identifiable, Equatable {
    let id: String
    let title: String
    let type: String
    let snippet: String

    init(row: Row) {
        id = row["id"]
        title = row["title"] ?? ""
        type = row["type"] ?? ""
        snippet = row["snippet"] ?? ""
    }
}

/// One belief row for the beliefs dashboard: the node joined with its subject
/// entity's title and the dispute flag.
struct MemoryBeliefRow: FetchableRecord, Identifiable, Equatable {
    let id: String
    let title: String
    let status: String // active | shaken | retired
    let confidence: Double
    let subjectTitle: String // resolved entity title, "" when unresolvable
    let disputeReason: String?

    init(row: Row) {
        id = row["id"]
        title = row["title"] ?? ""
        status = row["status"] ?? ""
        confidence = row["confidence"] ?? 0
        subjectTitle = row["subject_title"] ?? ""
        disputeReason = row["dispute_reason"]
    }

    var isDisputed: Bool { disputeReason != nil }
    var displayTitle: String { title.isEmpty ? id : title }
}

/// Aggregate header for the beliefs dashboard.
struct MemoryBeliefStats: Equatable {
    var total = 0
    var active = 0
    var shaken = 0
    var retired = 0
    var disputed = 0
    var averageConfidence = 0.0
}

/// One vault git commit shown in a node's History section. Parsed from
/// `git log` output, not from the DB.
struct MemoryCommit: Identifiable, Equatable {
    let hash: String
    let date: String // ISO date from git --date=iso-strict
    let subject: String // first line, e.g. "memory(extract): 2 episodes"

    var id: String { hash }

    /// Short day form for the timeline ("2026-07-17").
    var day: String { String(date.prefix(10)) }
}

/// A node file loaded from the vault: raw contents plus the body below the
/// frontmatter fences.
struct MemoryNodeFile: Equatable {
    let raw: String
    let body: String // markdown below the closing fence
}

/// One `[[id]]` / `[[id|label]]` occurrence in a node body (mirrors Go
/// `memory.Link`).
struct MemoryWikiLink: Equatable {
    let target: String
    let label: String // empty for label-less links
}

/// One resolved backlink: a node whose body links to the selected node.
struct MemoryBacklink: Identifiable, Equatable {
    let id: String // source node id
    let title: String
    let type: String
}

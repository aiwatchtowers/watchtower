import Foundation
import GRDB

// MARK: - Secretary memory vault models
//
// These mirror the Go memory index rows (see internal/db/memory.go): the
// SQLite side is a rebuildable mirror of the markdown vault (MEM-02), so
// everything here is read-side. File bodies come from the vault directory,
// not from these rows.

/// Master-list ordering for the Memory tab: `.recent` (today's default,
/// newest-indexed first) or `.important` (highest `importance_score` first).
package enum MemorySort: Hashable {
    case recent
    case important
}

/// One `memory_nodes` row as shown in the browser list, joined with the
/// dispute side table. Tombstones are filtered out at query level.
package struct MemoryNodeListItem: FetchableRecord, Identifiable, Equatable {
    package let id: String
    package let type: String // entity | episode | rollup | belief
    package let tier: String // short | long
    package let status: String // active | closed | shaken | retired
    package let title: String
    package let path: String // vault-relative file path
    package let indexedAt: String
    package let subject: String // belief subject entity id, "" otherwise
    package let confidence: Double // belief confidence 0..1, 0 otherwise
    package let importanceScore: Double // merged override-or-computed importance
    package let disputeReason: String? // non-nil when a dispute flag is pending

    package init(row: Row) {
        id = row["id"]
        type = row["type"] ?? ""
        tier = row["tier"] ?? ""
        status = row["status"] ?? ""
        title = row["title"] ?? ""
        path = row["path"] ?? ""
        indexedAt = row["indexed_at"] ?? ""
        subject = row["subject"] ?? ""
        confidence = row["confidence"] ?? 0
        importanceScore = row["importance_score"] ?? 0
        disputeReason = row["dispute_reason"]
    }

    package var isBelief: Bool { type == "belief" }
    package var isDisputed: Bool { disputeReason != nil }

    /// Falls back to the id for nodes whose body has no H1 yet.
    package var displayTitle: String { title.isEmpty ? id : title }
}

/// One FTS hit (mirrors Go `SearchMemoryFTS`): node identity plus a snippet
/// of the matched body region.
package struct MemorySearchHit: FetchableRecord, Identifiable, Equatable {
    package let id: String
    package let title: String
    package let type: String
    package let snippet: String

    package init(row: Row) {
        id = row["id"]
        title = row["title"] ?? ""
        type = row["type"] ?? ""
        snippet = row["snippet"] ?? ""
    }
}

/// One belief row for the beliefs dashboard: the node joined with its subject
/// entity's title and the dispute flag.
package struct MemoryBeliefRow: FetchableRecord, Identifiable, Equatable {
    package let id: String
    package let title: String
    package let status: String // active | shaken | retired
    package let confidence: Double
    package let subjectTitle: String // resolved entity title, "" when unresolvable
    package let disputeReason: String?

    package init(row: Row) {
        id = row["id"]
        title = row["title"] ?? ""
        status = row["status"] ?? ""
        confidence = row["confidence"] ?? 0
        subjectTitle = row["subject_title"] ?? ""
        disputeReason = row["dispute_reason"]
    }

    package var isDisputed: Bool { disputeReason != nil }
    package var displayTitle: String { title.isEmpty ? id : title }
}

/// Aggregate header for the beliefs dashboard.
package struct MemoryBeliefStats: Equatable {
    package var total = 0
    package var shaken = 0
    package var disputed = 0
    package var averageConfidence = 0.0

    package init(total: Int = 0, shaken: Int = 0, disputed: Int = 0, averageConfidence: Double = 0.0) {
        self.total = total
        self.shaken = shaken
        self.disputed = disputed
        self.averageConfidence = averageConfidence
    }
}

/// One vault git commit shown in a node's History section. Parsed from
/// `git log` output, not from the DB.
package struct MemoryCommit: Identifiable, Equatable {
    package let hash: String
    package let date: String // ISO date from git --date=iso-strict
    package let subject: String // first line, e.g. "memory(extract): 2 episodes"

    package var id: String { hash }

    /// Short day form for the timeline ("2026-07-17").
    package var day: String { String(date.prefix(10)) }

    package init(hash: String, date: String, subject: String) {
        self.hash = hash
        self.date = date
        self.subject = subject
    }
}

/// One `[[id]]` / `[[id|label]]` occurrence in a node body (mirrors Go
/// `memory.Link`).
package struct MemoryWikiLink: Equatable {
    package let target: String
    package let label: String // empty for label-less links

    package init(target: String, label: String) {
        self.target = target
        self.label = label
    }
}

/// One resolved backlink: a node whose body links to the selected node.
package struct MemoryBacklink: Identifiable, Equatable {
    package let id: String // source node id
    package let title: String
    package let type: String

    package init(id: String, title: String, type: String) {
        self.id = id
        self.title = title
        self.type = type
    }
}

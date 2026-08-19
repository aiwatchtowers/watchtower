import Foundation
import GRDB

// MARK: - Shared chat relevant-memory engine (Secretary Memory Slice C)
//
// Extracted from SituationChatViewModel's original relevantMemory/memorySection
// (Phase 4), generalized so Track/Target/Meeting chat can share the same
// ranking-and-render logic. Each chat type computes its own `subjects: [String]`
// (which Slack channel/user ids or emails this chat is "about") next to its own
// code, then calls into this file. Ranking now uses `memory_nodes.importance_score`
// (Slice A/B on the Go side, read here via the same shared SQLite mirror) instead
// of raw title/confidence order, and a new recent-activity section surfaces
// short-tier episodes by provenance recency (mirrors Go's
// ListShortTierEpisodesForAliases, Slice B).

package struct MemoryBelief {
    package let title: String
    package let confidence: Double
    package let status: String

    package init(title: String, confidence: Double, status: String) {
        self.title = title
        self.confidence = confidence
        self.status = status
    }
}

package struct MemoryContextResult {
    package let entityTitles: [String]
    package let beliefs: [MemoryBelief]
    package let recentEpisodeTitles: [String]

    package init(entityTitles: [String], beliefs: [MemoryBelief], recentEpisodeTitles: [String]) {
        self.entityTitles = entityTitles
        self.beliefs = beliefs
        self.recentEpisodeTitles = recentEpisodeTitles
    }
}

/// Pure GRDB index reads: entity nodes whose aliases match `subjects` (≤5,
/// ranked by importance_score DESC then title ASC), active/shaken beliefs
/// whose subject is one of those entities (≤5, ranked by importance_score DESC
/// then confidence DESC), and short-tier non-tombstone episodes whose
/// provenance sender matches `subjects` (≤5, ranked by recency, deduped per
/// node by its most recent matching ref). Tolerant of the memory tables being
/// absent (a DB that hasn't run the memory migrations) — a failed read
/// degrades to an empty result rather than throwing.
package func relevantMemoryContext(subjects: [String], dbPool: DatabasePool) -> MemoryContextResult {
    guard !subjects.isEmpty else {
        return MemoryContextResult(entityTitles: [], beliefs: [], recentEpisodeTitles: [])
    }

    do {
        return try dbPool.read { db in
            let placeholders = subjects.map { _ in "?" }.joined(separator: ",")

            let entityRows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT n.id AS id, n.title AS title
                FROM memory_nodes n
                JOIN memory_aliases a ON a.node_id = n.id
                WHERE n.type = 'entity' AND a.alias IN (\(placeholders))
                ORDER BY n.importance_score DESC, n.title ASC
                LIMIT 5
                """, arguments: StatementArguments(subjects))
            let entityIDs = entityRows.map { $0["id"] as String }
            let entityTitles = entityRows.map { $0["title"] as String }

            var beliefs: [MemoryBelief] = []
            if !entityIDs.isEmpty {
                let subjectPlaceholders = entityIDs.map { _ in "?" }.joined(separator: ",")
                let beliefRows = try Row.fetchAll(db, sql: """
                    SELECT title, confidence, status
                    FROM memory_nodes
                    WHERE type = 'belief' AND status IN ('active','shaken') AND subject IN (\(subjectPlaceholders))
                    ORDER BY importance_score DESC, confidence DESC
                    LIMIT 5
                    """, arguments: StatementArguments(entityIDs))
                beliefs = beliefRows.map {
                    MemoryBelief(title: $0["title"], confidence: $0["confidence"], status: $0["status"])
                }
            }

            let recentRows = try Row.fetchAll(db, sql: """
                SELECT n.title AS title
                FROM memory_nodes n
                JOIN (
                    SELECT node_id, MAX(ts_unix) AS max_ts
                    FROM memory_provenance
                    WHERE sender_id IN (\(placeholders))
                    GROUP BY node_id
                ) latest ON latest.node_id = n.id
                WHERE n.tier = 'short' AND n.status != 'tombstone'
                ORDER BY latest.max_ts DESC
                LIMIT 5
                """, arguments: StatementArguments(subjects))
            let recentEpisodeTitles = recentRows.map { $0["title"] as String }

            return MemoryContextResult(entityTitles: entityTitles, beliefs: beliefs, recentEpisodeTitles: recentEpisodeTitles)
        }
    } catch {
        print("RelevantMemory: memory read failed: \(error)")
        return MemoryContextResult(entityTitles: [], beliefs: [], recentEpisodeTitles: [])
    }
}

/// Reads `<vaultDir>/map.md` verbatim, trimmed. Nil when the vault dir is
/// unknown, the file is missing, or it is blank.
package func hotMap(vaultDir: String?) -> String? {
    guard let vaultDir else { return nil }
    let path = "\(vaultDir)/map.md"
    guard let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// The `=== MEMORY ===` block: the hot vault map plus the entities/beliefs/
/// recent activity this chat's subjects match. Framed as model-mediated notes
/// (not the owner's/attendee's own words) and capped at 4 KB. Always returns a
/// non-empty block — degrading to one-line notes when there is no map or
/// nothing relevant.
package func renderMemorySection(hotMap: String?, context: MemoryContextResult) -> String {
    var lines: [String] = [
        "=== MEMORY (notes the assistant has built from Slack/Jira — model-mediated, not the owner's own words) ==="
    ]

    if let hotMap {
        lines.append("Hot map:")
        lines.append(hotMap)
    } else {
        lines.append("Hot map: (none yet — the assistant hasn't written a memory map for this workspace).")
    }

    if context.entityTitles.isEmpty && context.beliefs.isEmpty && context.recentEpisodeTitles.isEmpty {
        lines.append("Relevant notes: (none match the people or channels here yet).")
    } else {
        if !context.entityTitles.isEmpty {
            lines.append("People & topics the assistant already tracks:")
            for title in context.entityTitles { lines.append("- \(title)") }
        }
        if !context.beliefs.isEmpty {
            lines.append("What the assistant believes (model-mediated, may be wrong):")
            for belief in context.beliefs {
                var line = "- \(belief.title) (confidence \(String(format: "%.2f", belief.confidence)), \(belief.status))"
                if belief.status == "shaken" { line += " (uncertain — evidence conflicts)" }
                lines.append(line)
            }
        }
        if !context.recentEpisodeTitles.isEmpty {
            lines.append("Recent activity (model-mediated):")
            for title in context.recentEpisodeTitles { lines.append("- \(title)") }
        }
    }

    return cap4KB(lines.joined(separator: "\n"))
}

/// Truncate `text` to at most 4 KB (UTF-8), on a line boundary so a partial
/// line is never emitted.
package func cap4KB(_ text: String) -> String {
    let limit = 4096
    guard text.utf8.count > limit else { return text }
    var result = ""
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let candidate = result.isEmpty ? String(line) : result + "\n" + line
        if candidate.utf8.count > limit { break }
        result = candidate
    }
    return result
}

import Foundation

/// `watchtower project check --project N --json` (PROJ-07, board target
/// #131): targets whose status disagrees with their git branch or pull
/// request. Go owns the check (`internal/projectcheck`); the Desktop only
/// decodes and shows it. Keys mirror `projectcheck.Report`/`Finding`; only
/// Go's `omitempty` fields may be absent.
package struct ProjectDriftReport: Decodable, Equatable, Sendable {
    package let git: Bool
    package let base: String
    package let incomplete: Bool
    package let findings: [ProjectDriftFinding]
    package let notes: [String]

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        git = try c.decode(Bool.self, forKey: .git)
        findings = try c.decode([ProjectDriftFinding].self, forKey: .findings)
        base = try c.decodeIfPresent(String.self, forKey: .base) ?? ""
        incomplete = try c.decodeIfPresent(Bool.self, forKey: .incomplete) ?? false
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case git, base, incomplete, findings, notes
    }

    /// The branch checks did not cover the whole board — not a git work
    /// tree, no default branch, or time ran out — so "no findings" does not
    /// mean the board and git agree.
    package var isPartial: Bool { incomplete || !git || base.isEmpty }
}

package struct ProjectDriftFinding: Decodable, Equatable, Sendable, Identifiable {
    package let targetID: Int
    package let title: String
    package let kind: String
    package let detail: String
    package let fix: String

    /// Go keeps one finding per kind per target.
    package var id: String { "\(targetID):\(kind)" }

    enum CodingKeys: String, CodingKey {
        case targetID = "target_id"
        case title, kind, detail, fix
    }

    /// The board says one thing and git certainly another — the kinds the
    /// Stop hook acts on (Go `Finding.Blocking`); the rest are advisory.
    package var isConflict: Bool { kind != "stale" && kind != "done_but_unmerged" }

    /// A short human label for the kind (Go `projectcheck.Kind*`).
    package var kindLabel: String {
        switch kind {
        case "merged_but_open": "Merged, still open"
        case "done_but_unmerged": "Done, not merged"
        case "branch_missing": "Branch missing"
        case "pr_closed_unmerged": "PR closed unmerged"
        case "stale": "No movement"
        default: kind
        }
    }
}

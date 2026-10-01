import Foundation

/// `watchtower project check --project N --json` (PROJ-07, board target
/// #131): targets whose status disagrees with their git branch or pull
/// request. Go owns the check (`internal/projectcheck`); the Desktop only
/// decodes and shows it. Field names mirror `projectcheck.Report`/`Finding`.
package struct ProjectDriftReport: Decodable, Equatable, Sendable {
    package let projectID: Int64
    package let git: Bool
    package let base: String
    package let incomplete: Bool
    package let findings: [ProjectDriftFinding]
    package let notes: [String]

    package init(
        projectID: Int64,
        git: Bool = true,
        base: String = "main",
        incomplete: Bool = false,
        findings: [ProjectDriftFinding],
        notes: [String] = []
    ) {
        self.projectID = projectID
        self.git = git
        self.base = base
        self.incomplete = incomplete
        self.findings = findings
        self.notes = notes
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try c.decode(Int64.self, forKey: .projectID)
        git = try c.decodeIfPresent(Bool.self, forKey: .git) ?? false
        base = try c.decodeIfPresent(String.self, forKey: .base) ?? ""
        incomplete = try c.decodeIfPresent(Bool.self, forKey: .incomplete) ?? false
        findings = try c.decodeIfPresent([ProjectDriftFinding].self, forKey: .findings) ?? []
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case git, base, incomplete, findings, notes
    }
}

package struct ProjectDriftFinding: Decodable, Equatable, Sendable, Identifiable {
    package let targetID: Int
    package let title: String
    package let status: String
    package let branch: String
    package let pr: String
    package let kind: String
    package let detail: String
    package let fix: String

    package var id: String { "\(targetID):\(kind)" }

    package init(
        targetID: Int,
        title: String,
        status: String,
        branch: String = "",
        pr: String = "",
        kind: String,
        detail: String,
        fix: String
    ) {
        self.targetID = targetID
        self.title = title
        self.status = status
        self.branch = branch
        self.pr = pr
        self.kind = kind
        self.detail = detail
        self.fix = fix
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targetID = try c.decode(Int.self, forKey: .targetID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        pr = try c.decodeIfPresent(String.self, forKey: .pr) ?? ""
        kind = try c.decode(String.self, forKey: .kind)
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        fix = try c.decodeIfPresent(String.self, forKey: .fix) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case targetID = "target_id"
        case title, status, branch, pr, kind, detail, fix
    }

    /// The board says one thing and git certainly another — the kinds the
    /// Stop hook acts on (Go `Finding.Blocking`); the rest are advisory.
    package var isConflict: Bool { kind != "stale" && kind != "done_but_unmerged" }

    /// A short human label for the kind.
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

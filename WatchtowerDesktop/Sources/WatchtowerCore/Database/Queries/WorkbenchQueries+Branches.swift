import Foundation
import GRDB

extension WorkbenchQueries {
    /// This workbench's targets that carry a git branch (`targets.branch`,
    /// written by the agent through `update_target`), keyed by the trimmed
    /// branch name — the branch popover's `#id` badges. Each list has the
    /// open targets first (anything but done/dismissed), then by id.
    package static func branchTargets(_ db: Database, projectID: Int64) throws -> [String: [WorkbenchBranchTarget]] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, text, status, TRIM(branch) AS branch FROM targets
            WHERE project_id = ? AND TRIM(COALESCE(branch, '')) <> ''
            ORDER BY CASE WHEN status IN ('done', 'dismissed') THEN 1 ELSE 0 END, id
            """, arguments: [projectID])
        var byBranch: [String: [WorkbenchBranchTarget]] = [:]
        for row in rows {
            byBranch[row["branch"], default: []].append(
                WorkbenchBranchTarget(id: row["id"], title: row["text"], status: row["status"])
            )
        }
        return byBranch
    }
}

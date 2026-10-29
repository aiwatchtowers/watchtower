import Foundation
import GRDB

extension CoachProposal {
    /// A `coach_proposals` row, for the readers that go to the table rather
    /// than the CLI (Home). `workbench_id` NULL (global) reads as 0, the CLI's
    /// form; the evidence is not read (nothing there shows it).
    init(row: Row) {
        self.init(
            id: row["id"], title: row["title"], why: row["why"], destination: row["destination"],
            workbenchID: (row["workbench_id"] as Int64?) ?? 0, promptID: row["prompt_id"],
            kind: row["kind"], metric: row["metric"], before: row["before_text"], after: row["after_text"],
            evidence: [], sources: row["sources"], status: row["status"], createdAt: row["created_at"],
            decidedAt: nil, baseline: row["baseline"], verdict: row["verdict"], verdictValue: row["verdict_value"],
            verdictAt: nil, revertsID: (row["reverts_id"] as Int64?) ?? 0, budget: 0)
    }
}

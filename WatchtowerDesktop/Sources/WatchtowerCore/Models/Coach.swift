import Foundation

/// Decoded `watchtower coach status --json` / `coach proposals --json`
/// (`cmd/coach.go`, pinned keys; the fixtures in `Tests/Core/Fixtures` mirror them).

package struct CoachMetric: Decodable, Equatable, Sendable {
    package let value: Double?
    package let n: Int
    package let known: Bool
    package let previous: Double?

    package init(value: Double?, n: Int, known: Bool, previous: Double?) {
        self.value = value
        self.n = n
        self.known = known
        self.previous = previous
    }
}

package struct CoachPeriod: Decodable, Equatable, Sendable {
    package let since: String
    package let until: String
}

package struct CoachMetrics: Decodable, Equatable, Sendable {
    package let corrections: CoachMetric
    package let taskHours: CoachMetric
    package let taskCostUSD: CoachMetric
    package let ownerLoop: CoachMetric
    package let specFindings: CoachMetric
    package let reviewComments: CoachMetric

    enum CodingKeys: String, CodingKey {
        case corrections
        case taskHours = "task_hours", taskCostUSD = "task_cost_usd", ownerLoop = "owner_loop"
        case specFindings = "spec_findings", reviewComments = "review_comments"
    }
}

package struct CoachStatus: Decodable, Equatable, Sendable {
    package let ok: Bool
    package let period: CoachPeriod
    package let metrics: CoachMetrics
    package let open: Int
    package let lastRun: String

    enum CodingKeys: String, CodingKey {
        case ok, period, metrics, open
        case lastRun = "last_run"
    }
}

package struct CoachEvidence: Decodable, Equatable, Sendable {
    package let kind: String
    package let ref: String
}

package struct CoachProposal: Decodable, Equatable, Identifiable, Sendable {
    package let id: Int64
    package let title: String
    package let why: String
    package let destination: String
    /// 0 = global.
    package let workbenchID: Int64
    package let promptID: String
    package let kind: String
    package let metric: String
    package let before: String
    package let after: String
    package let evidence: [CoachEvidence]
    package let sources: Int
    package let status: String
    package let createdAt: String
    package let decidedAt: String?
    package let baseline: Double?
    package let verdict: String
    package let verdictValue: Double?
    package let verdictAt: String?
    package let revertsID: Int64
    /// Runes the destination allows; 0 = no budget.
    package let budget: Int
    /// The skill a skill destination edits (`claude_skill_user`,
    /// `codex_skill_user`, `pack_overlay`); absent for the others.
    package var skill: String?
    /// `weekly` (the coach's run) or `chat` (the tuning chat); an older CLI
    /// that has no `origin` key reads as `weekly`.
    package var origin = "weekly"
    /// The tuning chat a `chat` proposal came from; nil for weekly ones and
    /// once that conversation is deleted.
    package var conversationID: Int64?
    /// `repo_*`: the branch Accept wrote on; "" otherwise or before Accept.
    package var writtenBranch = ""
    /// `repo_*`: when the accepted text was first seen committed at HEAD
    /// (the verdict window starts there); nil = not yet, or not `repo_*`.
    package var measureFrom: String?
    /// Open `repo_*` rows only: the branch now checked out in the workbench
    /// folder, read by the CLI at list time ("" = not a git folder); nil when
    /// the key is absent. Never read from the database row.
    package var folderBranch: String?

    enum CodingKeys: String, CodingKey {
        case id, title, why, destination, kind, metric, before, after, evidence, sources, status
        case baseline, verdict, budget, skill, origin
        case workbenchID = "workbench_id", promptID = "prompt_id", createdAt = "created_at"
        case decidedAt = "decided_at", verdictValue = "verdict_value", verdictAt = "verdict_at"
        case revertsID = "reverts_id", conversationID = "conversation_id"
        case writtenBranch = "written_branch", measureFrom = "measure_from", folderBranch = "folder_branch"
    }
}

extension CoachProposal {
    /// Written out (in an extension, so the memberwise init stays) only for
    /// the keys an older CLI does not print: they decode to their defaults.
    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(Int64.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title),
            why: try c.decode(String.self, forKey: .why),
            destination: try c.decode(String.self, forKey: .destination),
            workbenchID: try c.decode(Int64.self, forKey: .workbenchID),
            promptID: try c.decode(String.self, forKey: .promptID),
            kind: try c.decode(String.self, forKey: .kind),
            metric: try c.decode(String.self, forKey: .metric),
            before: try c.decode(String.self, forKey: .before),
            after: try c.decode(String.self, forKey: .after),
            evidence: try c.decode([CoachEvidence].self, forKey: .evidence),
            sources: try c.decode(Int.self, forKey: .sources),
            status: try c.decode(String.self, forKey: .status),
            createdAt: try c.decode(String.self, forKey: .createdAt),
            decidedAt: try c.decodeIfPresent(String.self, forKey: .decidedAt),
            baseline: try c.decodeIfPresent(Double.self, forKey: .baseline),
            verdict: try c.decode(String.self, forKey: .verdict),
            verdictValue: try c.decodeIfPresent(Double.self, forKey: .verdictValue),
            verdictAt: try c.decodeIfPresent(String.self, forKey: .verdictAt),
            revertsID: try c.decode(Int64.self, forKey: .revertsID),
            budget: try c.decode(Int.self, forKey: .budget),
            skill: try c.decodeIfPresent(String.self, forKey: .skill),
            origin: try c.decodeIfPresent(String.self, forKey: .origin) ?? "weekly",
            conversationID: try c.decodeIfPresent(Int64.self, forKey: .conversationID),
            writtenBranch: try c.decodeIfPresent(String.self, forKey: .writtenBranch) ?? "",
            measureFrom: try c.decodeIfPresent(String.self, forKey: .measureFrom),
            folderBranch: try c.decodeIfPresent(String.self, forKey: .folderBranch))
    }
}

package struct CoachProposalList: Decodable, Equatable, Sendable {
    package let ok: Bool
    package let proposals: [CoachProposal]
}

/// The failure object `--json` writes to stderr, followed by a prose line.
package struct CoachFailure: Decodable, Equatable, Sendable {
    package let ok: Bool
    package let error: String
    package let code: String?
    package let diff: String?

    /// The last stderr line that decodes as a JSON object with an `ok` key
    /// (the CLI prints a prose error line after the JSON one).
    package static func parse(stderr: String) -> Self? {
        for line in stderr.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["ok"] != nil,
                  let failure = try? JSONDecoder().decode(Self.self, from: data)
            else { continue }
            return failure
        }
        return nil
    }
}

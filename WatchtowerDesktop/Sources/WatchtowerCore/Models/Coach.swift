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

    enum CodingKeys: String, CodingKey {
        case id, title, why, destination, kind, metric, before, after, evidence, sources, status
        case baseline, verdict, budget
        case workbenchID = "workbench_id", promptID = "prompt_id", createdAt = "created_at"
        case decidedAt = "decided_at", verdictValue = "verdict_value", verdictAt = "verdict_at"
        case revertsID = "reverts_id"
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

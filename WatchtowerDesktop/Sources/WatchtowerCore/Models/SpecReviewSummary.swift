import Foundation

/// The reviewer's state as one line of text, shared by the Desktop screen
/// (counts) and the mobile `owner_ask` slice (`spec_review`).
package enum SpecReviewSummary {
    /// "9 as agreed · 1 differs · 1 missing · 4 decided alone · 2 blind
    /// spots"; zero counts are left out.
    package static func countsLine(_ result: SpecReviewResult) -> String {
        let agreed = result.agreements.filter { $0.status == "as_agreed" }.count
        let differs = result.agreements.filter { $0.status == "differs" }.count
        let missing = result.agreements.filter { $0.status == "missing" }.count
        let other = result.agreements.count - agreed - differs - missing
        let parts: [(Int, String)] = [
            (agreed, "as agreed"), (differs, "differs"), (missing, "missing"), (other, "other"),
            (result.decidedAlone.count, "decided alone"),
            (result.blindSpots.count, result.blindSpots.count == 1 ? "blind spot" : "blind spots")
        ]
        let line = parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
        return line.isEmpty ? "No findings" : line
    }

    /// The Desktop's one-line state for a row that is waiting, running,
    /// failed or skipped; nil for done and unknown (the caller words those).
    package static func stateLine(_ row: SpecReviewRow) -> String? {
        switch row.status {
        case .queued: return "Reviewer is waiting to start…"
        case .running: return "Reviewer is reading the spec and the discussion…"
        case .failed: return reasonLine("Reviewer failed", row.reason)
        case .skipped: return reasonLine("Reviewer skipped", row.reason)
        case .done, .unknown: return nil
        }
    }

    /// "Reviewer failed: <reason>", or the bare label without a reason.
    private static func reasonLine(_ label: String, _ reason: String) -> String {
        reason.isEmpty ? label : "\(label): \(reason)"
    }

    /// The phone's line: counts for a done review, "Reviewer is reading…"
    /// while queued or running, the reason for failed or skipped. Never
    /// empty; nil for a state this build does not know. The caller clips it.
    package static func phoneLine(_ row: SpecReviewRow) -> (status: String, line: String)? {
        switch row.status {
        case .queued, .running: return (row.status.rawValue, "Reviewer is reading…")
        case .done:
            guard let result = row.result else { return ("done", "The reviewer's result could not be read") }
            return ("done", countsLine(result))
        case .failed, .skipped: return stateLine(row).map { (row.status.rawValue, $0) }
        case .unknown: return nil
        }
    }
}

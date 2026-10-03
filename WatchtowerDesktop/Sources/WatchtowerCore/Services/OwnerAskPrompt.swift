import Foundation

/// The one line typed into an ask's session after the owner answers it
/// (spec 2026-10-03 Part 5). It names the ask only — the agent reads the
/// answer itself through `get_ask`. Dual path of Go's `asks.DeliveryLine`,
/// pinned by `internal/asks/testdata/lines`. Pure.
package enum OwnerAskPrompt {
    package static func line(id: Int64, kind: OwnerAskKind, answer: OwnerAskAnswer) -> String {
        WorkbenchCommentPrompt.oneLine(
            "Ask #\(id) answered (\(kind.rawValue): \(short(kind, answer))) — read it with get_ask \(id) using the watchtower-workbench skill."
        )
    }

    private static func short(_ kind: OwnerAskKind, _ answer: OwnerAskAnswer) -> String {
        switch (kind, answer.verdict) {
        case (.review, .approved): return "approved"
        case (.review, .changes): return "changes requested"
        case (.check, _):
            let states = answer.checklist.map(\.state)
            func count(_ state: OwnerAskAnswer.CheckState) -> Int { states.filter { $0 == state }.count }
            return "\(count(.ok)) ok, \(count(.broken)) broken, \(count(.skipped)) skipped"
        default: return "answered"
        }
    }
}

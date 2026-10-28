import Foundation
import WatchtowerCore

/// An open coach proposal built the way the CLI sends it (its JSON), for the
/// view and shot tests that need one without the database.
package enum CoachProposalFixture {
    package static func make(
        id: Int64 = 1,
        title: String = "t",
        destination: String = "session",
        workbench: Int64 = 0,
        before: String = "",
        after: String = ""
    ) -> CoachProposal {
        let obj: [String: Any] = [
            "id": id, "title": title, "why": "w", "destination": destination, "workbench_id": workbench,
            "prompt_id": "", "kind": "add", "metric": "corrections", "before": before, "after": after,
            "evidence": [], "sources": 3, "status": "open", "created_at": "2026-10-20T00:00:00Z",
            "verdict": "", "reverts_id": 0, "budget": 0
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)  // swiftlint:disable:this force_try
        return try! JSONDecoder().decode(CoachProposal.self, from: data)  // swiftlint:disable:this force_try
    }
}

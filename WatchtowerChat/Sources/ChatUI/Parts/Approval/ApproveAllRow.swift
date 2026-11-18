import ChatWire
import SwiftUI

/// **Approve all** under a reply whose turn has two or more cards to approve (a session-applied call is left to its own
/// card, which offers Approve only while its chat session holds it). Only where the screen approves in bulk: the Mac.
struct ApproveAllRow: View {
    static let label = "Approve all"

    let turnID: String
    let approveAll: (String) -> Void

    var body: some View {
        Button(Self.label) { approveAll(turnID) }
            .font(.caption)
    }

    /// The turn whose cards **Approve all** covers under a reply with these actions: two or more pending ones that are
    /// not session calls, of one turn. Nil draws no button.
    static func turn(of actions: [ChatAgentAction]) -> String? {
        let bulk = actions.filter { $0.isPending && !$0.isSessionApplied && !$0.turnID.isEmpty }
        guard bulk.count >= 2, let turn = bulk.first?.turnID else { return nil }
        return turn
    }
}

import Foundation

/// One card the tuning chat shows inside its feed. Only proposal cards today
/// (the A/B replay card was dropped, spec D61).
package enum TuningCard: Equatable, Identifiable, Sendable {
    case proposal(Int64)

    package var id: String {
        switch self {
        case .proposal(let id): return "proposal-\(id)"
        }
    }
}

/// Where the tuning chat's cards sit in the feed (spec 2026-11-03 §3): a
/// proposal filed by a `propose_tuning_edit` call sits under the turn that made
/// the call; a proposal of the conversation with no such call (its action row
/// gone, or filed some other way) goes after the last turn. A card is listed
/// once.
package struct TuningFeedCards: Equatable, Sendable {
    package static let proposeTool = "propose_tuning_edit"

    package var byTurn: [String: [TuningCard]]
    package var trailing: [TuningCard]

    /// `actions` are the conversation's `agent_actions` rows; `proposals` the
    /// conversation's chat proposals (`CoachProposal.forChat`), in their order.
    /// Only an applied call anchors a card: a refused or failed one filed
    /// nothing. The call's `result_json` carries `proposal_id` (Go
    /// `internal/tuning/tools_propose.go`).
    package static func build(actions: [AgentAction], proposals: [CoachProposal]) -> Self {
        var byTurn: [String: [TuningCard]] = [:]
        var placed = Set<Int64>()
        for action in actions.sorted(by: { $0.id < $1.id }) {
            guard action.tool == proposeTool, action.status == "applied", !action.turnID.isEmpty,
                  let raw = action.resultString("proposal_id"), let id = Int64(raw),
                  placed.insert(id).inserted else { continue }
            byTurn[action.turnID, default: []].append(.proposal(id))
        }
        var trailing: [TuningCard] = []
        for proposal in proposals where placed.insert(proposal.id).inserted {
            trailing.append(.proposal(proposal.id))
        }
        return Self(byTurn: byTurn, trailing: trailing)
    }
}

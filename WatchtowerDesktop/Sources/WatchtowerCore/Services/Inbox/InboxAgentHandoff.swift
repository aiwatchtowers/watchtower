import Foundation

/// Which workbench Hand to Agent… works in (spec B2): the action's own
/// `workbench` (an id, or a name matched without case), else a workbench
/// recipe's own workbench. A ref that names no existing workbench, a name two
/// workbenches share, and a personal card with no ref are the owner's pick.
package enum InboxAgentHandoff {
    package enum Resolution: Equatable, Sendable {
        case workbench(Int64)
        case pick
    }

    package static func workbench(
        for ref: InboxCardAction.WorkbenchRef?,
        card: AutomationOutputCard,
        workbenches: [Workbench]
    ) -> Resolution {
        workbench(for: ref, cardWorkbenchID: card.workbenchID, workbenches: workbenches)
    }

    /// The same rule for a card of any kind: `cardWorkbenchID` is the card's
    /// own workbench (`InboxCardSubject.workbenchID`), nil for a personal one.
    package static func workbench(
        for ref: InboxCardAction.WorkbenchRef?,
        cardWorkbenchID: Int64?,
        workbenches: [Workbench]
    ) -> Resolution {
        let matches: [Workbench] = switch ref {
        case .id(let id): workbenches.filter { $0.id == id }
        case .name(let name): workbenches.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        case nil: workbenches.filter { $0.id == cardWorkbenchID }
        }
        guard matches.count == 1, let only = matches.first else { return .pick }
        return .workbench(only.id)
    }
}

import Foundation
import WatchtowerCore

/// Maps an Inbox target button's facts onto DesignKit's one state type
/// (spec "The Desktop button", its table). Pure; the button in the reading
/// pane and the approval card of its proposal both draw from it.
enum TargetButtonStateResolver {
    /// How long after its approval (`decided_at`) an `approved` or
    /// `executing` row with no process of ours on it is still in flight: a
    /// `create_target` apply takes milliseconds, so one older than this
    /// belongs to a process that died.
    static let targetButtonStuckAfter: TimeInterval = 120

    static func state(_ facts: InboxTargetButtonFacts, now: Date) -> ArtifactTargetButtonState {
        let idle: ArtifactTargetButtonState = facts.pressError.map { .proposeError(message: $0) } ?? .idle
        guard let proposal = facts.proposal else { return idle }
        switch proposal.status {
        case "pending":
            return .waiting
        case "approved", "executing":
            if facts.inFlight { return .creating }
            // An unreadable `decided_at` counts as old: Try again is safe
            // (one task per action id, Go AGENT-05), a spinner forever is not.
            if let decided = proposal.decidedDate, now.timeIntervalSince(decided) < targetButtonStuckAfter {
                return .creating
            }
            // A Try again whose CLI failed without moving the row.
            if let applyError = facts.applyError { return .failed(message: applyError) }
            return .stuck
        case "applied":
            return facts.taskExists ? .created : idle
        case "failed":
            guard proposal.dismissedAt.isEmpty else { return idle }
            let message = facts.applyError ?? proposal.error
            return .failed(message: message.isEmpty ? "The task was not created." : message)
        default:
            // `rejected`: the owner said no to that proposal, not to the button.
            return idle
        }
    }
}

/// What a card's target buttons read from the Inbox center, threaded from
/// the split view to the card: the facts per context id, whether a press is
/// under way, and the moment the stuck rule is told from. The default
/// (tests, the shots) draws every button idle.
struct InboxTargetButtonSource {
    var facts: (String) -> InboxTargetButtonFacts = { _ in InboxTargetButtonFacts() }
    var isProposing: (String) -> Bool = { _ in false }
    var now = Date()

    /// The button of `target` at flattened `index` on `card`.
    func button(_ target: InboxCardAction.Target, index: Int, card: AutomationOutputCard)
        -> (facts: InboxTargetButtonFacts, state: ArtifactTargetButtonState, context: String) {
        let context = InboxTargetPress.contextID(outputID: card.id, index: index, hash: target.hash)
        let facts = facts(context)
        return (facts, TargetButtonStateResolver.state(facts, now: now), context)
    }

    /// The command of a click on that button; nil while it is being created
    /// or its propose is under way.
    func command(_ target: InboxCardAction.Target, index: Int, card: AutomationOutputCard) -> InboxCardCommand? {
        let button = button(target, index: index, card: card)
        guard !isProposing(button.context) else { return nil }
        return InboxCardPress.target(target, index: index, card: card, facts: button.facts, state: button.state)
    }
}

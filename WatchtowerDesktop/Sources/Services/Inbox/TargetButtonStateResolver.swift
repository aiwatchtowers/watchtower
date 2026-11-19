import Foundation
import WatchtowerCore
import WatchtowerInterface

/// Maps an Inbox target button onto DesignKit's one state type (spec "The
/// Desktop button", its table). Go decides the button's state from the
/// database (`InboxTargetButton.detail`); the Mac lays only its own
/// processes over it: a propose that failed, an apply of ours still
/// running or failed, and the moment a creating button turns stuck by the
/// clock (Go's `until`, which no write wakes the feed for). The button in
/// the reading pane and the approval card of its proposal both draw from it.
enum TargetButtonStateResolver {
    /// A failed button whose row carries no message.
    static let notCreated = "The task was not created."

    static func state(_ button: InboxTargetButton, now: Date) -> ArtifactTargetButtonState {
        let idle: ArtifactTargetButtonState = button.pressError.map { .proposeError(message: $0) } ?? .idle
        switch button.detail {
        case "waiting":
            return .waiting
        case "creating", "stuck":
            if button.inFlight { return .creating }
            if button.detail == "creating", let until = button.until, now < until { return .creating }
            // A Try again whose apply failed without moving the row.
            if let applyError = button.applyError { return .failed(message: applyError) }
            return .stuck
        case "created":
            return .created
        case "failed":
            let message = button.applyError ?? button.note
            return .failed(message: message.isEmpty ? notCreated : message)
        default:
            // Idle, and a state this build does not know.
            return idle
        }
    }
}

/// What a card's buttons read from the Inbox center, threaded from the
/// split view to the card: the feed's card (its buttons' state), each
/// target button with this Desktop's processes on it, whether a press is
/// under way, and the moment the stuck rule is told from. The default
/// (tests, the shots) has no feed: Replies draw closed and target buttons idle.
struct InboxTargetButtonSource {
    /// The feed's card of an output id.
    var card: (Int64) -> Card? = { _ in nil }
    var button: (_ context: String, _ action: CardAction?) -> InboxTargetButton = { _, action in
        InboxTargetButton(action: action)
    }
    var isProposing: (String) -> Bool = { _ in false }
    var now = Date()

    /// The output's buttons as the feed draws them.
    func feedButtons(_ outputID: Int64) -> InboxFeedButtons {
        InboxFeedButtons(card(outputID))
    }

    /// The button of `target` at flattened `index` on `card`.
    func button(_ target: InboxCardAction.Target, index: Int, card: AutomationOutputCard)
        -> (button: InboxTargetButton, state: ArtifactTargetButtonState, context: String) {
        let context = InboxTargetPress.contextID(outputID: card.id, index: index, hash: target.hash)
        let drawn = button(context, feedButtons(card.id).action(at: index))
        return (drawn, TargetButtonStateResolver.state(drawn, now: now), context)
    }

    /// The command of a click on that button; nil while it is being created
    /// or its propose is under way.
    func command(_ target: InboxCardAction.Target, index: Int, card: AutomationOutputCard) -> InboxCardCommand? {
        let drawn = button(target, index: index, card: card)
        guard !isProposing(drawn.context) else { return nil }
        return InboxCardPress.target(target, index: index, card: card, button: drawn.button, state: drawn.state)
    }
}

@MainActor
extension ActionStripViewModel {
    /// The cards' buttons from this center: every Inbox reading pane (the
    /// folder Inbox and the legacy split) draws them from it.
    func targetButtons(now: Date) -> InboxTargetButtonSource {
        InboxTargetButtonSource(
            card: { self.feedCard("o\($0)") },
            button: { self.targetButton(contextID: $0, action: $1) },
            isProposing: { self.proposingTargets.contains($0) },
            now: now
        )
    }
}

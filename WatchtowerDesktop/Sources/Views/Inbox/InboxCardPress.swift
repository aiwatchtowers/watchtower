import Foundation
import WatchtowerCore

/// What a press of one of a card's buttons does, shared by the card's own
/// button row (`InboxCardButtons`) and a card drawn from blocks
/// (`InboxArtifactCard`): a command for `AppState.perform`, or the
/// workbench picker for an agent press that names no one workbench.
enum InboxCardPress: Equatable {
    case command(InboxCardCommand)
    /// Open the workbench picker; the pick sends this task.
    case pick(task: String)

    /// The press of `action` on `card`. A Reply carries the action's index
    /// in the card's flattened action list and the content hash the card
    /// was drawn at; one whose recipe cannot run opens its automation,
    /// where it is confirmed or turned on (spec B3).
    static func resolve(
        _ action: InboxCardAction, card: AutomationOutputCard, reply: InboxReplyState, workbenches: [Workbench]
    ) -> Self {
        switch action.kind {
        case .link(let url):
            return .command(.openLink(url))
        case .chat(let message):
            return .command(.chat(InboxCardSubject(card), message: message))
        case let .agent(task, ref):
            // The recipe's task, then the card fenced as data (as Hand to
            // Agent… sends it): a card can quote anyone.
            let full = InboxCardTexts.agentActionTask(card, task: task)
            switch InboxAgentHandoff.workbench(for: ref, card: card, workbenches: workbenches) {
            case .workbench(let id): return .command(.agent(InboxCardSubject(card), task: full, workbench: .id(id)))
            case .pick where !workbenches.isEmpty: return .pick(task: full)
            case .pick: return .command(.agent(InboxCardSubject(card), task: full, workbench: ref))
            }
        case .reply:
            guard reply == .ready else { return .command(.openAutomation(card)) }
            return .command(.reply(outputID: card.id, action: action.index, contentHash: card.contentHash))
        }
    }

    /// A button that cannot be pressed now: a link the link rules refuse, a
    /// Reply already sent or whose recipe is gone, or any Reply while a
    /// press of the card is under way.
    static func isDisabled(
        _ action: InboxCardAction, reply: InboxReplyState, isWriting: Bool, navScreens: Set<String>
    ) -> Bool {
        switch action.kind {
        case .link(let url):
            return !InboxCardLinkPolicy.permits(url, navScreens: navScreens)
        case .chat, .agent:
            return false
        case .reply:
            switch reply {
            case .sent, .removed: return true
            case .ready, .needsConfirmation, .off, .unreadable: return isWriting
            }
        }
    }
}

extension InboxCardAction {
    /// A block or card action decoded by the Kit, at its flattened `index`.
    /// Nil for what the Inbox does not press yet — a `target` button (the
    /// approval-card flow) — or an `open` without a URL scheme.
    init?(_ action: ArtifactAction, index: Int) {
        let kind: Kind
        switch action.payload {
        case .open(let text):
            guard let url = URL(string: text), url.scheme != nil else { return nil }
            kind = .link(url)
        case .chat(let message):
            kind = .chat(message)
        case let .agent(task, workbench):
            kind = .agent(task: task, workbench: workbench.map {
                switch $0 {
                case .id(let id): .id(id)
                case .name(let name): .name(name)
                }
            })
        case let .reply(value, _):
            kind = .reply(value: value)
        case .target:
            return nil
        }
        self.init(index: index, label: action.label, kind: kind, primary: action.primary)
    }
}

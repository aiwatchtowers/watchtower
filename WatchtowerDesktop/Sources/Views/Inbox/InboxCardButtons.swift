import SwiftUI
import WatchtowerCore

/// What a press on an Inbox card asks the app to do. The card's views only
/// emit it; `ActionStripView` carries it out.
enum InboxCardCommand: Equatable {
    /// A card link (`link`, an action's `open`), checked again at press time.
    case openLink(URL)
    /// AI Chat with the card attached and `message` in the composer, not sent.
    case chat(card: AutomationOutputCard, message: String)
    /// A target with `task` and a session in a workbench.
    case agent(card: AutomationOutputCard, task: String, workbench: InboxCardAction.WorkbenchRef?)
    /// A Reply press: `action` is the stored index (`InboxCardAction.index`).
    case reply(outputID: Int64, action: Int)
    /// The automation's card, where a recipe that cannot run is confirmed or
    /// turned on.
    case openAutomation(AutomationOutputCard)
}

/// An automation card's two button rows (spec B2): its own actions, the
/// first one prominent unless it set `primary: false`; then the common row,
/// Open source (only with a link), Discuss in Chat and Hand to Agent…, with
/// Done and Dismiss trailing.
struct InboxCardButtons: View {
    let card: AutomationOutputCard
    /// The screens a `watchtower-nav://` link may open.
    let navScreens: Set<String>
    /// A Done, Dismiss or Reply press of this card is under way.
    var isWriting = false
    let onCommand: (InboxCardCommand) -> Void
    var onDone: () -> Void = {}
    var onDismiss: () -> Void = {}

    var body: some View {
        let actions = InboxCardAction.decode(card.actionsJSON)
        let reply = InboxCardAction.replyState(card)
        VStack(alignment: .leading, spacing: Spacing.regular) {
            if !actions.isEmpty {
                HStack(spacing: Spacing.regular) {
                    ForEach(actions, id: \.index) { action in
                        ownButton(action, reply: reply)
                    }
                    if actions.contains(where: \.isReply), let caption = Self.caption(reply) {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            commonRow
        }
        .controlSize(.small)
    }

    // MARK: - The card's own buttons

    @ViewBuilder
    private func ownButton(_ action: InboxCardAction, reply: InboxReplyState) -> some View {
        let button = Button(Self.label(action, card: card, reply: reply)) { press(action, reply: reply) }
            .disabled(isDisabled(action, reply: reply))
            .help(Self.help(action))
        if action.primary {
            button.buttonStyle(.kitPrimary)
        } else {
            button.buttonStyle(.kitSecondary)
        }
    }

    private func press(_ action: InboxCardAction, reply: InboxReplyState) {
        switch action.kind {
        case .link(let url):
            onCommand(.openLink(url))
        case .chat(let message):
            onCommand(.chat(card: card, message: message))
        case let .agent(task, workbench):
            onCommand(.agent(card: card, task: task, workbench: workbench))
        case .reply:
            // A recipe that cannot run: its card is where it is confirmed or
            // turned on (spec B3).
            if reply == .ready {
                onCommand(.reply(outputID: card.id, action: action.index))
            } else {
                onCommand(.openAutomation(card))
            }
        }
    }

    private func isDisabled(_ action: InboxCardAction, reply: InboxReplyState) -> Bool {
        switch action.kind {
        case .link(let url):
            return !InboxCardLinkPolicy.permits(url, navScreens: navScreens)
        case .chat, .agent:
            return false
        case .reply:
            if case .sent = reply { return true }
            return isWriting
        }
    }

    /// The pressed Reply reads "Sent — run #N"; every other button keeps
    /// the label its recipe wrote.
    static func label(_ action: InboxCardAction, card: AutomationOutputCard, reply: InboxReplyState) -> String {
        guard action.isReply, case let .sent(runID) = reply, card.pressedAction == action.index else {
            return action.label
        }
        return runID.map { "Sent — run #\($0)" } ?? "Sent"
    }

    /// Why the Reply buttons will not send right now.
    static func caption(_ reply: InboxReplyState) -> String? {
        switch reply {
        case .ready, .sent: nil
        case .needsConfirmation: "Needs confirmation"
        case .off: "Off"
        case .unreadable: "Recipe can't be read"
        }
    }

    private static func help(_ action: InboxCardAction) -> String {
        switch action.kind {
        case .link(let url): url.absoluteString
        case .chat: "Opens AI Chat with this card"
        case .agent: "Hands this card to an agent"
        case .reply: "Sends this choice to the automation"
        }
    }

    // MARK: - The common row

    private var commonRow: some View {
        HStack(spacing: Spacing.regular) {
            if let source = URL(string: card.link), !card.link.isEmpty {
                Button("Open source") { onCommand(.openLink(source)) }
                    .disabled(!InboxCardLinkPolicy.permits(source, navScreens: navScreens))
                    .help(card.link)
            }
            Button("Discuss in Chat") {
                onCommand(.chat(card: card, message: InboxCardTexts.discussMessage(card)))
            }
            Button("Hand to Agent…") {
                onCommand(.agent(card: card, task: InboxCardTexts.handToAgentTask(card), workbench: nil))
            }
            Spacer(minLength: Spacing.medium)
            Group {
                Button("Done", action: onDone)
                Button("Dismiss", action: onDismiss)
            }
            .disabled(isWriting)
        }
        .buttonStyle(.kitQuiet)
    }
}

private extension InboxCardAction {
    var isReply: Bool {
        if case .reply = kind { return true }
        return false
    }
}

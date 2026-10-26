import SwiftUI
import WatchtowerCore

/// An automation card's two button rows (spec B2): its own actions, the
/// first one prominent unless it set `primary: false`; then the common row
/// (`InboxCommonRow`) with Done and Dismiss trailing. An Agent press that
/// names no one workbench opens a picker anchored to the button.
struct InboxCardButtons: View {
    let card: AutomationOutputCard
    /// The screens a `watchtower-nav://` link may open.
    let navScreens: Set<String>
    /// A Done, Dismiss or Reply press of this card is under way.
    var isWriting = false
    let onCommand: (InboxCardCommand) -> Void
    var onDone: () -> Void = {}
    var onDismiss: () -> Void = {}
    /// The workbenches an agent press can go to.
    var workbenches: [Workbench] = []

    /// An agent press waiting for the owner's workbench: the action's index
    /// (the button it is anchored to) and its task.
    private struct AgentPick: Equatable {
        let anchor: Int
        let task: String
    }

    @State private var picking: AgentPick?

    var body: some View {
        let actions = InboxCardAction.decode(card.actionsJSON)
        let reply = InboxCardAction.replyState(card)
        VStack(alignment: .leading, spacing: Spacing.regular) {
            if !actions.isEmpty {
                // Up to four 40-character labels: the row wraps in a narrow pane.
                FlowLayout(spacing: Spacing.regular) {
                    ForEach(actions, id: \.index) { action in
                        ownButton(action, reply: reply)
                    }
                    if actions.contains(where: \.isReply), let caption = Self.caption(reply) {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, Spacing.small)
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
            .help(help(action))
            .popover(isPresented: isPicking(action.index), arrowEdge: .bottom) {
                InboxWorkbenchPicker(workbenches: workbenches, onPick: pick).popoverSurface()
            }
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
            onCommand(.chat(InboxCardSubject(card), message: message))
        case let .agent(task, workbench):
            // The recipe's task, then the card fenced as data (as Hand to
            // Agent… sends it): a card can quote anyone.
            handToAgent(task: InboxCardTexts.agentActionTask(card, task: task), ref: workbench, anchor: action.index)
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
            switch reply {
            case .sent, .removed: return true
            case .ready, .needsConfirmation, .off, .unreadable: return isWriting
            }
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
        case .removed: "Recipe removed"
        }
    }

    private func help(_ action: InboxCardAction) -> String {
        switch action.kind {
        case .link(let url): url.absoluteString
        case .chat: "Opens Chats with this card"
        case let .agent(task, ref): InboxCardTexts.agentActionHelp(task, workbench: workbenchName(for: ref))
        case .reply: "Sends this choice to the automation"
        }
    }

    /// The workbench an agent press goes to without a picker, by name.
    private func workbenchName(for ref: InboxCardAction.WorkbenchRef?) -> String? {
        guard case .workbench(let id) = InboxAgentHandoff.workbench(for: ref, card: card, workbenches: workbenches)
        else { return nil }
        return workbenches.first { $0.id == id }?.name
    }

    // MARK: - The common row

    private var commonRow: some View {
        InboxCommonRow(
            subject: InboxCardSubject(card),
            link: card.link.isEmpty ? nil : URL(string: card.link),
            discussMessage: InboxCardTexts.discussMessage(card),
            navScreens: navScreens,
            workbenches: workbenches,
            isWriting: isWriting,
            onCommand: onCommand
        ) {
            Button("Done", action: onDone)
            Button("Dismiss", action: onDismiss)
        }
    }
}

// MARK: - The workbench picker

extension InboxCardButtons {
    /// The resolved workbench goes out as an id; with none resolved, the
    /// picker opens, or — no workbench at all — the press goes out as it is
    /// and `AppState.perform` says why it cannot be handed over.
    private func handToAgent(task: String, ref: InboxCardAction.WorkbenchRef?, anchor: Int) {
        switch InboxAgentHandoff.workbench(for: ref, card: card, workbenches: workbenches) {
        case .workbench(let id):
            onCommand(.agent(InboxCardSubject(card), task: task, workbench: .id(id)))
        case .pick where !workbenches.isEmpty:
            picking = AgentPick(anchor: anchor, task: task)
        case .pick:
            onCommand(.agent(InboxCardSubject(card), task: task, workbench: ref))
        }
    }

    private func isPicking(_ anchor: Int) -> Binding<Bool> {
        Binding(get: { picking?.anchor == anchor }, set: { if !$0 { picking = nil } })
    }

    private func pick(_ workbenchID: Int64) {
        guard let pick = picking else { return }
        picking = nil
        onCommand(.agent(InboxCardSubject(card), task: pick.task, workbench: .id(workbenchID)))
    }
}

private extension InboxCardAction {
    var isReply: Bool {
        if case .reply = kind { return true }
        return false
    }
}

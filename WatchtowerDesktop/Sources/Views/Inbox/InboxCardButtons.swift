import SwiftUI
import WatchtowerCore

/// An automation card's two button rows (spec B2): its own actions, the
/// first one prominent unless it set `primary: false`; then the common row
/// (`InboxCommonRow`) with Done and Dismiss trailing. An Agent press that
/// names no one workbench opens a picker anchored to the button. A card
/// drawn from blocks draws its own actions with its blocks
/// (`InboxArtifactCard`) and passes `drawsOwnActions: false`.
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
    /// False: only the common row (the card's actions are drawn with its blocks).
    var drawsOwnActions = true
    /// The target buttons' state, from the Inbox center.
    let targets: InboxTargetButtonSource
    /// False: no Done or Dismiss in the common row (a card in Needs
    /// approval, `InboxReadingPane.stackedInApprovals()`).
    var showsDoneDismiss = true

    /// An agent press waiting for the owner's workbench: the action's index
    /// (the button it is anchored to) and its task.
    private struct AgentPick: Equatable {
        let anchor: Int
        let task: String
    }

    @State private var picking: AgentPick?

    var body: some View {
        let actions = drawsOwnActions ? InboxCardAction.ownActions(card) : []
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
        if case .target(let target) = action.kind {
            targetButton(action, target: target)
        } else {
            plainButton(action, reply: reply)
        }
    }

    /// A target button: DesignKit's view over the state its proposal gives.
    private func targetButton(_ action: InboxCardAction, target: InboxCardAction.Target) -> some View {
        let button = targets.button(target, index: action.index, card: card)
        return ArtifactTargetButton(label: action.label, state: button.state, mode: .inbox) {
            if let command = targets.command(target, index: action.index, card: card) { onCommand(command) }
        }
        .disabled(targets.isProposing(button.context))
    }

    @ViewBuilder
    private func plainButton(_ action: InboxCardAction, reply: InboxReplyState) -> some View {
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
        switch InboxCardPress.resolve(action, card: card, reply: reply, workbenches: workbenches) {
        case .command(let command): onCommand(command)
        case .pick(let task): picking = AgentPick(anchor: action.index, task: task)
        case .nothing: break
        }
    }

    private func isDisabled(_ action: InboxCardAction, reply: InboxReplyState) -> Bool {
        InboxCardPress.isDisabled(action, reply: reply, isWriting: isWriting, navScreens: navScreens)
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
        case .target: "Proposes a task; you approve it"
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
            if showsDoneDismiss {
                Button("Done", action: onDone)
                Button("Dismiss", action: onDismiss)
            }
        }
    }
}

// MARK: - The workbench picker

extension InboxCardButtons {
    private func isPicking(_ anchor: Int) -> Binding<Bool> {
        Binding(get: { picking?.anchor == anchor }, set: { if !$0 { picking = nil } })
    }

    private func pick(_ workbenchID: Int64) {
        guard let pick = picking else { return }
        picking = nil
        onCommand(.agent(InboxCardSubject(card), task: pick.task, workbench: .id(workbenchID)))
    }
}

extension InboxCardAction {
    /// A card's own buttons in stored order, through the Kit's decoder (it
    /// alone hashes a target action); a column the Kit cannot read falls
    /// back to Core's tolerant decoder, which drops target actions.
    static func ownActions(_ card: AutomationOutputCard) -> [InboxCardAction] {
        guard case let .actions(actions) = ArtifactDocument.decodeActions(card.actionsJSON) else {
            return decode(card.actionsJSON)
        }
        return actions.enumerated().compactMap { Self($0.element, index: $0.offset) }
    }
}

private extension InboxCardAction {
    var isReply: Bool {
        if case .reply = kind { return true }
        return false
    }
}

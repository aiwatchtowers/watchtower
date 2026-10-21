import SwiftUI
import WatchtowerCore

/// What a press on an Inbox card asks the app to do. The card's views only
/// emit it; `AppState.perform` carries it out.
enum InboxCardCommand: Equatable {
    /// A card link (`link`, an action's `open`), checked again at press time.
    case openLink(URL)
    /// AI Chat with the card attached and `message` in the composer, not sent.
    case chat(card: AutomationOutputCard, message: String)
    /// A target with `task` and a session in a workbench. The buttons emit
    /// the workbench they resolved (`InboxAgentHandoff`) or the owner picked.
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
/// Done and Dismiss trailing. A Hand to Agent… or Agent press that names no
/// one workbench opens a picker anchored to the button.
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

    /// An agent press waiting for the owner's workbench: the button it is
    /// anchored to (an action's index, or `commonRowAnchor`) and its task.
    private struct AgentPick: Equatable {
        let anchor: Int
        let task: String
    }

    private static let commonRowAnchor = -1
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
            .popover(isPresented: isPicking(action.index), arrowEdge: .bottom) { workbenchPicker.popoverSurface() }
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
        case .chat: "Opens AI Chat with this card"
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

    /// The leading buttons wrap in a narrow pane; Done and Dismiss stay on
    /// the first line, trailing.
    private var commonRow: some View {
        HStack(alignment: .top, spacing: Spacing.medium) {
            FlowLayout(spacing: Spacing.regular) {
                if let source = URL(string: card.link), !card.link.isEmpty {
                    Button("Open source") { onCommand(.openLink(source)) }
                        .disabled(!InboxCardLinkPolicy.permits(source, navScreens: navScreens))
                        .help(card.link)
                }
                Button("Discuss in Chat") {
                    onCommand(.chat(card: card, message: InboxCardTexts.discussMessage(card)))
                }
                Button("Hand to Agent…") {
                    handToAgent(task: InboxCardTexts.handToAgentTask(card), ref: nil, anchor: Self.commonRowAnchor)
                }
                .popover(isPresented: isPicking(Self.commonRowAnchor), arrowEdge: .bottom) { workbenchPicker.popoverSurface() }
            }
            HStack(spacing: Spacing.regular) {
                Button("Done", action: onDone)
                Button("Dismiss", action: onDismiss)
            }
            .fixedSize()
            .disabled(isWriting)
        }
        .buttonStyle(.kitQuiet)
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
            onCommand(.agent(card: card, task: task, workbench: .id(id)))
        case .pick where !workbenches.isEmpty:
            picking = AgentPick(anchor: anchor, task: task)
        case .pick:
            onCommand(.agent(card: card, task: task, workbench: ref))
        }
    }

    private func isPicking(_ anchor: Int) -> Binding<Bool> {
        Binding(get: { picking?.anchor == anchor }, set: { if !$0 { picking = nil } })
    }

    private var workbenchPicker: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Hand to which workbench?")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(workbenches) { workbench in
                Button(workbench.name) {
                    guard let pick = picking else { return }
                    picking = nil
                    onCommand(.agent(card: card, task: pick.task, workbench: .id(workbench.id)))
                }
                .buttonStyle(.kitQuiet)
            }
        }
        .controlSize(.small)
        .padding(Spacing.medium)
    }
}

private extension InboxCardAction {
    var isReply: Bool {
        if case .reply = kind { return true }
        return false
    }
}

import SwiftUI
import WatchtowerCore

/// What a press on an Inbox card asks the app to do. The card's views only
/// emit it; `AppState.perform` carries it out.
enum InboxCardCommand: Equatable {
    /// A card link (`link`, an action's `open`), checked again at press time.
    case openLink(URL)
    /// AI Chat with the card attached and `message` in the composer, not sent.
    case chat(InboxCardSubject, message: String)
    /// A target with `task` and a session in a workbench. The buttons emit
    /// the workbench they resolved (`InboxAgentHandoff`) or the owner picked.
    case agent(InboxCardSubject, task: String, workbench: InboxCardAction.WorkbenchRef?)
    /// A Reply press: `action` is the stored index (`InboxCardAction.index`).
    case reply(outputID: Int64, action: Int)
    /// The automation's card, where a recipe that cannot run is confirmed or
    /// turned on.
    case openAutomation(AutomationOutputCard)
}

/// The button row every Inbox card shares (spec B2, C1 §6.2): Open source
/// (only with a link, under the kind's own label), Discuss in Chat and Hand
/// to Agent…, then the kind's own trailing buttons (Done, Dismiss, Hide,
/// Snooze…), which wait while a press of the card is under way. A Hand to
/// Agent… that names no one workbench opens the picker anchored to it.
struct InboxCommonRow<Trailing: View>: View {
    let subject: InboxCardSubject
    let link: URL?
    /// "Open source", or the kind's own ("Open in Slack").
    let openLabel: String
    /// Discuss in Chat's first message (an automation card keeps its own text).
    let discussMessage: String
    /// The screens a `watchtower-nav://` link may open.
    let navScreens: Set<String>
    let workbenches: [Workbench]
    let isWriting: Bool
    let showsHandToAgent: Bool
    let onCommand: (InboxCardCommand) -> Void
    let trailing: Trailing

    @State private var picking = false

    init(
        subject: InboxCardSubject,
        link: URL?,
        openLabel: String = "Open source",
        discussMessage: String? = nil,
        navScreens: Set<String>,
        workbenches: [Workbench],
        isWriting: Bool,
        showsHandToAgent: Bool = true,
        onCommand: @escaping (InboxCardCommand) -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.subject = subject
        self.link = link
        self.openLabel = openLabel
        self.discussMessage = discussMessage ?? InboxCardTexts.discussMessage(subject)
        self.navScreens = navScreens
        self.workbenches = workbenches
        self.isWriting = isWriting
        self.showsHandToAgent = showsHandToAgent
        self.onCommand = onCommand
        self.trailing = trailing()
    }

    /// The leading buttons wrap in a narrow pane; the trailing ones stay on
    /// the first line.
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.medium) {
            FlowLayout(spacing: Spacing.regular) {
                if let link {
                    Button(openLabel) { onCommand(.openLink(link)) }
                        .disabled(!InboxCardLinkPolicy.permits(link, navScreens: navScreens))
                        .help(link.absoluteString)
                }
                Button("Discuss in Chat") {
                    onCommand(.chat(subject, message: discussMessage))
                }
                if showsHandToAgent {
                    Button("Hand to Agent…", action: handToAgent)
                        .popover(isPresented: $picking, arrowEdge: .bottom) {
                            InboxWorkbenchPicker(workbenches: workbenches) { id in
                                picking = false
                                onCommand(.agent(subject, task: task, workbench: .id(id)))
                            }
                            .popoverSurface()
                        }
                }
            }
            HStack(spacing: Spacing.regular) {
                trailing
            }
            .fixedSize()
            .disabled(isWriting)
        }
        .buttonStyle(.kitQuiet)
        .controlSize(.small)
    }

    private var task: String { InboxCardTexts.handToAgentTask(subject) }

    /// The card's own workbench goes out as an id; with none resolved, the
    /// picker opens, or — no workbench at all — the press goes out as it is
    /// and `AppState.perform` says why it cannot be handed over.
    private func handToAgent() {
        switch InboxAgentHandoff.workbench(for: nil, cardWorkbenchID: subject.workbenchID, workbenches: workbenches) {
        case .workbench(let id): onCommand(.agent(subject, task: task, workbench: .id(id)))
        case .pick where !workbenches.isEmpty: picking = true
        case .pick: onCommand(.agent(subject, task: task, workbench: nil))
        }
    }
}

/// The small picker an agent press opens when the card names no one
/// workbench (the style guide's anchored-picker popover).
struct InboxWorkbenchPicker: View {
    let workbenches: [Workbench]
    let onPick: (Int64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Hand to which workbench?")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(workbenches) { workbench in
                Button(workbench.name) { onPick(workbench.id) }
                    .buttonStyle(.kitQuiet)
            }
        }
        .controlSize(.small)
        .padding(Spacing.medium)
    }
}

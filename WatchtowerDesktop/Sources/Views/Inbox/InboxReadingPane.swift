import SwiftUI
import WatchtowerCore

/// The Inbox's reading pane (spec B1, C1 §6.2): the selected row read in
/// full. An automation card shows where it came from (a link to its run),
/// its title, its body as markdown under the chat's link rules, and its
/// buttons; a reminder its note, its Slack message and Done / Snooze 1h; a
/// pending `save_automation` proposal its summary (`SaveAutomationProposalPane`),
/// any other proposal its `AgentActionCardView`; a message its
/// `InboxMessagePane`. The day, track and idea cards come from `dayCard`,
/// `trackCard` and `ideaCard` (Tasks 8–10); `InboxCardPlaceholder` shows a
/// card's title and source line until then. The track card lays out its
/// own column (`InboxTrackPane`: its chat sits below the scrolling card).
struct InboxReadingPane<DayCard: View, TrackCard: View, IdeaCard: View>: View {
    let item: InboxListItem?
    /// The screens a `watchtower-nav://` link may open.
    let navScreens: Set<String>
    /// The moment a reminder's due time is told from ("Reminder · 14:00").
    let now: Date
    /// The shown card's Done, Dismiss, Snooze or Reply is under way.
    let isWriting: Bool
    let onCommand: (InboxCardCommand) -> Void
    /// The source line of an automation card: its run. Nil (tests) renders
    /// it as plain text.
    let onOpenAutomationRun: ((Int64) -> Void)?
    let onDone: () -> Void
    /// An output's Dismiss, a message's Hide.
    let onDismiss: () -> Void
    /// A reminder's Snooze 1h ("1h"), a message's Snooze choice ("1d", "3d", "1w").
    let onSnooze: (String) -> Void
    /// A proposal's card; nil (tests) leaves the pane empty for proposals.
    let proposalCard: ((AgentAction) -> AgentActionCardView)?
    /// A pending `save_automation` proposal's pane; nil shows its card.
    let saveProposal: ((AgentAction) -> SaveAutomationProposalPane)?
    /// The workbenches a card's agent press can go to.
    let workbenches: [Workbench]
    let dayCard: (InboxDayCard) -> DayCard
    let trackCard: (InboxTrackCard) -> TrackCard
    let ideaCard: (Idea) -> IdeaCard

    init(
        item: InboxListItem?,
        navScreens: Set<String>,
        now: Date = Date(),
        isWriting: Bool = false,
        onCommand: @escaping (InboxCardCommand) -> Void,
        onOpenAutomationRun: ((Int64) -> Void)? = nil,
        onDone: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void = {},
        onSnooze: @escaping (String) -> Void = { _ in },
        proposalCard: ((AgentAction) -> AgentActionCardView)? = nil,
        saveProposal: ((AgentAction) -> SaveAutomationProposalPane)? = nil,
        workbenches: [Workbench] = [],
        @ViewBuilder dayCard: @escaping (InboxDayCard) -> DayCard,
        @ViewBuilder trackCard: @escaping (InboxTrackCard) -> TrackCard,
        @ViewBuilder ideaCard: @escaping (Idea) -> IdeaCard
    ) {
        self.item = item
        self.navScreens = navScreens
        self.now = now
        self.isWriting = isWriting
        self.onCommand = onCommand
        self.onOpenAutomationRun = onOpenAutomationRun
        self.onDone = onDone
        self.onDismiss = onDismiss
        self.onSnooze = onSnooze
        self.proposalCard = proposalCard
        self.saveProposal = saveProposal
        self.workbenches = workbenches
        self.dayCard = dayCard
        self.trackCard = trackCard
        self.ideaCard = ideaCard
    }

    /// The pane's one readable column (style guide: "one readable column").
    static var readableWidth: CGFloat { InboxCardColumn<EmptyView>.readableWidth }

    var body: some View {
        switch item {
        case .output(let card):
            column { output(card) }
        case .reminder(let reminder):
            column { self.reminder(reminder) }
        case .proposal(let action):
            if action.tool == SaveAutomationCardModel.tool, action.isPending, let saveProposal {
                column { saveProposal(action) }
            } else if let proposalCard {
                column { proposalCard(action) }
            } else {
                nothingSelected
            }
        case .day(let card):
            column { dayCard(card) }
        case .track(let card):
            trackCard(card)
        case .idea(let idea):
            column { ideaCard(idea) }
        case .message(let row):
            column {
                InboxMessagePane(row: row, isWriting: isWriting, onDone: onDone, onHide: onDismiss,
                                 onSnooze: onSnooze, onCommand: onCommand, workbenches: workbenches,
                                 navScreens: navScreens, now: now)
            }
        case nil:
            nothingSelected
        }
    }

    private func column(@ViewBuilder _ content: () -> some View) -> some View {
        InboxCardColumn(content: content)
    }

    private var nothingSelected: some View {
        Text("Select a card")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - An automation card

    private func output(_ card: AutomationOutputCard) -> some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            source(card)
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Text(card.title.isEmpty ? "Automation output" : card.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if card.priority == "high" {
                    Chip(text: "High", color: Tone.priority("high"))
                }
            }
            if !card.body.isEmpty {
                MarkdownView(text: card.body)
            }
            InboxCardButtons(card: card, navScreens: navScreens, isWriting: isWriting, onCommand: onCommand,
                             onDone: onDone, onDismiss: onDismiss, workbenches: workbenches)
                .padding(.top, Spacing.small)
        }
    }

    @ViewBuilder
    private func source(_ card: AutomationOutputCard) -> some View {
        let line = InboxCardTexts.readingSourceLine(card)
        if let onOpenAutomationRun {
            Button(line) { onOpenAutomationRun(card.runID) }
                .buttonStyle(.kitQuiet)
                .controlSize(.small)
                .help("Open the automation run")
        } else {
            Text(line).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - A reminder

    private func reminder(_ reminder: Reminder) -> some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(InboxListRow.reminderSource(reminder, now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(reminder.note.isEmpty ? "Reminder" : reminder.note)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let message = SlackMessageRef.url(reminder.messageRef) {
                Link("Slack message ↗", destination: message)
                    .font(.callout)
            }
            HStack(spacing: Spacing.regular) {
                Button("Done", action: onDone)
                Button("Snooze 1h") { onSnooze("1h") }
            }
            .buttonStyle(.kitSecondary)
            .controlSize(.small)
            .disabled(isWriting)
            .padding(.top, Spacing.small)
        }
    }
}

extension InboxReadingPane
where DayCard == InboxCardPlaceholder, TrackCard == InboxCardColumn<InboxCardPlaceholder>,
      IdeaCard == InboxCardPlaceholder {
    /// Day, track and idea cards as their title and source line.
    init(
        item: InboxListItem?,
        navScreens: Set<String>,
        now: Date = Date(),
        isWriting: Bool = false,
        onCommand: @escaping (InboxCardCommand) -> Void,
        onOpenAutomationRun: ((Int64) -> Void)? = nil,
        onDone: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void = {},
        onSnooze: @escaping (String) -> Void = { _ in },
        proposalCard: ((AgentAction) -> AgentActionCardView)? = nil,
        saveProposal: ((AgentAction) -> SaveAutomationProposalPane)? = nil,
        workbenches: [Workbench] = []
    ) {
        self.init(
            item: item, navScreens: navScreens, now: now, isWriting: isWriting, onCommand: onCommand,
            onOpenAutomationRun: onOpenAutomationRun, onDone: onDone, onDismiss: onDismiss, onSnooze: onSnooze,
            proposalCard: proposalCard, saveProposal: saveProposal, workbenches: workbenches,
            dayCard: { InboxCardPlaceholder(day: $0) },
            trackCard: { card in InboxCardColumn { InboxCardPlaceholder(track: card, now: now) } },
            ideaCard: { InboxCardPlaceholder(idea: $0) }
        )
    }
}

/// A card in the reading pane's one readable column, scrolling.
struct InboxCardColumn<Content: View>: View {
    static var readableWidth: CGFloat { 640 }

    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: Self.readableWidth, alignment: .leading)
                .padding(Spacing.page)
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

/// A day, track or idea card before its own pane: the list row's title and
/// source line.
struct InboxCardPlaceholder: View {
    let title: String
    let source: String

    init(day: InboxDayCard) {
        title = InboxListRow.dayTitle(day)
        source = InboxListRow.daySource(day)
    }

    init(track: InboxTrackCard, now: Date) {
        let content = InboxListRow.content(.track(track), proposalLabel: nil, now: now)
        title = content.title
        source = content.source
    }

    init(idea: Idea) {
        title = idea.title
        source = InboxListRow.ideaSource(idea)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(source)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

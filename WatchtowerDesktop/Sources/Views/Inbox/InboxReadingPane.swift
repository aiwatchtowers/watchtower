import SwiftUI
import WatchtowerCore

/// The Inbox's reading pane (spec B1): the selected row read in full. An
/// automation card shows where it came from (a link to its run), its title,
/// its body as markdown under the chat's link rules, and its buttons; a
/// reminder its note, its Slack message and Done / Snooze 1h; a proposal its
/// `AgentActionCardView`, which has room to read here.
struct InboxReadingPane: View {
    let item: InboxListItem?
    /// The screens a `watchtower-nav://` link may open.
    let navScreens: Set<String>
    /// The moment a reminder's due time is told from ("Reminder · 14:00").
    var now = Date()
    /// The shown card's Done, Dismiss, Snooze or Reply is under way.
    var isWriting = false
    let onCommand: (InboxCardCommand) -> Void
    /// The source line of an automation card: its run. Nil (tests) renders
    /// it as plain text.
    var onOpenAutomationRun: ((Int64) -> Void)?
    var onDone: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onSnooze: () -> Void = {}
    /// A proposal's card; nil (tests) leaves the pane empty for proposals.
    var proposalCard: ((AgentAction) -> AgentActionCardView)?

    /// The pane's one readable column (style guide: "one readable column").
    static let readableWidth: CGFloat = 640

    var body: some View {
        switch item {
        case .output(let card):
            column { output(card) }
        case .reminder(let reminder):
            column { self.reminder(reminder) }
        case .proposal(let action):
            if let proposalCard {
                column { proposalCard(action) }
            } else {
                nothingSelected
            }
        case nil:
            nothingSelected
        }
    }

    private func column(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: Self.readableWidth, alignment: .leading)
                .padding(Spacing.page)
                .frame(maxWidth: .infinity, alignment: .top)
        }
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
                             onDone: onDone, onDismiss: onDismiss)
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
                Button("Snooze 1h", action: onSnooze)
            }
            .buttonStyle(.kitSecondary)
            .controlSize(.small)
            .disabled(isWriting)
            .padding(.top, Spacing.small)
        }
    }
}

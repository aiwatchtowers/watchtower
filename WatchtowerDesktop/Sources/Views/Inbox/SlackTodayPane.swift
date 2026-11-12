import SwiftUI
import WatchtowerCore

/// Slack today's reading pane (inbox redesign phase 5, mockup `slack`): its
/// header from the state ("Today · N messages in K conversations · M with news
/// for you") with **Mark All Seen**, Run Now and the ⋯; yesterday's note
/// while the card is the day before's; the artifact (`artifact`, the
/// reading pane's own card); then the folded line of conversations with nothing
/// for the owner, drawn from the state, not the card, so a quiet message
/// never marks the card unread.
struct SlackTodayPane: View {
    let card: AutomationOutputCard
    let state: SlackTodayState
    let now: Date
    let calendar: Calendar
    /// The artifact's ⋯; nil (tests, shots) draws neither it nor Run Now.
    let menu: InboxArtifactMenuState?
    let onMarkAllSeen: () -> Void
    /// The `?`; nil draws none.
    let onReactionCommands: (() -> Void)?
    /// The card's body, filled in by the reading pane (`InboxReadingPane.slackToday(_:)`).
    var artifact = AnyView(EmptyView())

    @State private var quietShown: Bool

    init(
        card: AutomationOutputCard,
        state: SlackTodayState,
        now: Date,
        calendar: Calendar,
        menu: InboxArtifactMenuState?,
        onMarkAllSeen: @escaping () -> Void,
        onReactionCommands: (() -> Void)?,
        quietShown: Bool = false
    ) {
        self.card = card
        self.state = state
        self.now = now
        self.calendar = calendar
        self.menu = menu
        self.onMarkAllSeen = onMarkAllSeen
        self.onReactionCommands = onReactionCommands
        _quietShown = State(initialValue: quietShown)
    }

    /// This pane around `artifact`.
    func drawing(_ artifact: some View) -> Self {
        var pane = self
        pane.artifact = AnyView(artifact)
        return pane
    }

    /// Today's summary only: yesterday's quiet channels are not today's.
    private var today: SlackTodaySummary? {
        guard let summary = state.summary, summary.isToday(now: now, calendar: calendar) else { return nil }
        return summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.page) {
            header
            if let note = SlackTodayPaneText.staleNote(state: state, writtenAt: card.writtenAt, now: now,
                                                       calendar: calendar) {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("slackToday.staleNote")
            }
            artifact
            if let today, let line = today.quietLine {
                quietFold(today, line: line)
            }
        }
    }

    /// The artifact header (Run Now, the ⋯, the `?`) with the state's line
    /// under the title and **Mark All Seen** first.
    private var header: some View {
        InboxArtifactPaneHeader(
            content: InboxRowContent(kind: .slackToday, title: SlackTodayRow.title),
            subtitle: SlackTodayPaneText.subtitle(state: state, now: now, calendar: calendar),
            menu: menu, onReactionCommands: onReactionCommands
        )
        .leadingAction(
            Button("Mark All Seen", action: onMarkAllSeen)
                .buttonStyle(.kitSecondary)
                .disabled(!card.isUnread)
                .help("Mark this list seen; a new line makes it unread again")
                .accessibilityIdentifier("slackToday.markAllSeen"))
    }

    /// "N conversations with nothing for you · M messages", folded by default;
    /// open, "#name · N messages" busiest first, then "and N more conversations"
    /// for the ones the state keeps no name of.
    private func quietFold(_ today: SlackTodaySummary, line: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Button {
                quietShown.toggle()
            } label: {
                Label {
                    Text(line)
                } icon: {
                    Image(systemName: quietShown ? "chevron.down" : "chevron.right")
                        .font(.system(size: IconSize.chevron, weight: .semibold))
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Quiet text, not the accent: these channels hold nothing for the owner.
            .buttonStyle(KitQuietButtonStyle(label: .secondary))
            .accessibilityIdentifier("slackToday.quietLine")
            if quietShown {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    // By offset: names are not unique (two DMs can share a display name).
                    ForEach(Array(today.quiet.enumerated()), id: \.offset) { _, channel in
                        Text("\(SlackTodaySummary.heading(channel.name)) · "
                            + SlackTodaySummary.plural(channel.messages, "message", "messages"))
                    }
                    if let more = today.quietMoreLine {
                        Text(more)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.leading, Spacing.wide)
            }
        }
    }
}

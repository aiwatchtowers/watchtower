import SwiftUI
import WatchtowerCore

/// Slack today's reading pane (inbox redesign phase 5, mockup `slack`): its
/// header from the state ("Today · N messages in K channels · M with news
/// for you") with **Mark All Seen**, Run Now and the ⋯; yesterday's note
/// while the card is the day before's; the artifact (`artifact`, the
/// reading pane's own card); then the folded line of channels with nothing
/// for the owner, drawn from the state, not the card, so a quiet message
/// never marks the card unread.
struct SlackTodayPane: View {
    let card: AutomationOutputCard
    let summary: SlackTodaySummary?
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
        summary: SlackTodaySummary?,
        now: Date,
        calendar: Calendar,
        menu: InboxArtifactMenuState?,
        onMarkAllSeen: @escaping () -> Void,
        onReactionCommands: (() -> Void)?,
        quietShown: Bool = false
    ) {
        self.card = card
        self.summary = summary
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

    private var offersRunNow: Bool {
        menu?.entries.contains { $0.command == .runNow } ?? false
    }

    /// Today's summary only: yesterday's quiet channels are not today's.
    private var today: SlackTodaySummary? {
        guard let summary, summary.isToday(now: now, calendar: calendar) else { return nil }
        return summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.page) {
            header
            if let note = SlackTodayPaneText.staleNote(summary: summary, writtenAt: card.writtenAt, now: now,
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

    private var header: some View {
        InboxPaneHeader(tile: InboxTile(kind: .slackToday), title: SlackTodayRow.title,
                        subtitle: SlackTodayPaneText.subtitle(summary: summary, now: now, calendar: calendar)) {
            Button("Mark All Seen", action: onMarkAllSeen)
                .buttonStyle(.kitSecondary)
                .disabled(!card.isUnread)
                .help("Mark this list seen; a new line makes it unread again")
                .accessibilityIdentifier("slackToday.markAllSeen")
            if let menu {
                if offersRunNow {
                    Button("Run Now") { menu.onCommand(.runNow) }
                        .buttonStyle(.kitSecondary)
                        .disabled(menu.isDisabled || menu.isWorking)
                        .accessibilityIdentifier("inbox.paneHeader.runNow")
                }
                InboxArtifactMenuButton(menu: menu)
            }
            if let onReactionCommands {
                InboxReactionCommandsButton(action: onReactionCommands)
            }
        }
    }

    /// "N channels with nothing for you · M messages", folded by default;
    /// open, "#name · N messages" busiest first, then "and N more channels"
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

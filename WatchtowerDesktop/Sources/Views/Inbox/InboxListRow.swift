import SwiftUI
import WatchtowerCore

/// One row of the Inbox list (spec B1): an unread dot, the title on one
/// line with a High chip, the source line and a one-line preview.
struct InboxListRow: View {
    let item: InboxListItem
    /// A proposal's "⚙ <automation> · run #<n>" when an automation run made it.
    var proposalLabel: String?
    let now: Date

    var body: some View {
        let content = Self.content(item, proposalLabel: proposalLabel, now: now)
        HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
            Circle()
                .fill(content.unread ? Color.accentColor : .clear)
                .frame(width: Self.dotSize, height: Self.dotSize)
                .accessibilityHidden(!content.unread)
                .accessibilityLabel("Unread")
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.compact) {
                    Text(content.title)
                        .font(.callout.weight(content.unread ? .semibold : .regular))
                        .lineLimit(1)
                    if content.high {
                        Chip(text: "High", color: Tone.priority("high"))
                    }
                }
                Text(content.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !content.preview.isEmpty {
                    Text(content.preview)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, Spacing.small)
    }

    private static let dotSize: CGFloat = 7

    struct Content: Equatable {
        let unread: Bool
        let title: String
        let high: Bool
        let source: String
        let preview: String
    }

    /// The row's words. A proposal is "unread" while it waits on the owner.
    static func content(_ item: InboxListItem, proposalLabel: String?, now: Date) -> Content {
        switch item {
        case .output(let card):
            return Content(unread: card.isUnread, title: card.title.isEmpty ? "Automation output" : card.title,
                           high: card.priority == "high", source: InboxCardTexts.sourceLine(card, now: now),
                           preview: InboxCardTexts.preview(card.body))
        case .reminder(let reminder):
            return Content(unread: false, title: reminder.note.isEmpty ? "Reminder" : reminder.note, high: false,
                           source: reminderSource(reminder, now: now), preview: "")
        case .proposal(let action):
            let title = action.tool == SaveAutomationCardModel.tool
                ? SaveAutomationCardModel(action: action).title
                : AgentActionCardView.title(for: action)
            let prefix = proposalLabel ?? "Assistant proposal"
            let source = AutomationDates.parse(action.createdAt)
                .map { InboxCardTexts.stamped(prefix, at: $0, now: now) } ?? prefix
            return Content(unread: action.isPending, title: title, high: false, source: source,
                           preview: action.reason)
        case .day(let card):
            return Content(unread: card.isUnread, title: dayTitle(card), high: false, source: daySource(card),
                           preview: dayPreview(card))
        case .track(let card):
            return Content(unread: card.isUnread, title: card.track.text, high: card.track.priority == "high",
                           source: InboxCardTexts.stamped("Track", at: card.lastEventAt, now: now),
                           preview: card.newEventCount > 0 ? "\(card.newEventCount) new" : "")
        case .idea(let idea):
            return Content(unread: idea.awaitsVerdict, title: idea.title, high: false, source: ideaSource(idea),
                           preview: idea.essence)
        case .message(let row):
            return Content(unread: row.item.isUnread, title: messageTitle(row), high: row.item.priority == "high",
                           source: messageSource(row, now: now), preview: row.item.whyMatters)
        }
    }

    /// The day card: its briefing, or the plan alone; today's placeholder
    /// before either exists.
    static func dayTitle(_ card: InboxDayCard) -> String {
        if card.briefing != nil { return "Morning brief" }
        return card.plan != nil ? "Day plan" : "Nothing ready yet"
    }

    /// "Your day · Wed 22 Oct".
    static func daySource(_ card: InboxDayCard) -> String {
        guard let date = dayParser.date(from: card.date) else { return "Your day · \(card.date)" }
        return "Your day · \(dayFormatter.string(from: date))"
    }

    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()

    private static func dayPreview(_ card: InboxDayCard) -> String {
        card.plan == nil ? "" : "Plan: \(card.planDone) of \(card.planTotal) done"
    }

    /// "Idea · proposed", "Decision · not now".
    static func ideaSource(_ idea: Idea) -> String {
        "\(idea.kind.rawValue.capitalized) · \(idea.statusRaw.replacingOccurrences(of: "_", with: " "))"
    }

    /// A channel item that folded several messages says how many; any other
    /// its text.
    static func messageTitle(_ row: HomeFeedInboxRow) -> String {
        if row.item.isAccumulated { return row.item.mentionCountTitle }
        var text = row.item.snippet
        // A mail's snippet is "<subject> — <text>" and the source line already
        // names the subject (`HomeFeedQueries.whereText`).
        if row.item.triggerType == "email_received", let range = text.range(of: " — ") {
            text = String(text[range.upperBound...])
        }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "Message" : line
    }

    /// "<who> · #eng · 09:12" (its day when not today).
    static func messageSource(_ row: HomeFeedInboxRow, now: Date) -> String {
        let prefix = [row.who, row.whereText ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        return InboxCardTexts.stamped(prefix.isEmpty ? "Message" : prefix, at: row.stamp, now: now)
    }

    /// "Reminder · 14:00" (its due time).
    static func reminderSource(_ reminder: Reminder, now: Date) -> String {
        AutomationDates.parse(reminder.remindAt)
            .map { InboxCardTexts.stamped("Reminder", at: $0, now: now) } ?? "Reminder"
    }
}

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
        }
    }

    /// "Reminder · 14:00" (its due time).
    static func reminderSource(_ reminder: Reminder, now: Date) -> String {
        AutomationDates.parse(reminder.remindAt)
            .map { InboxCardTexts.stamped("Reminder", at: $0, now: now) } ?? "Reminder"
    }
}

import Foundation

/// One row of the Inbox list.
package enum InboxListItem: Identifiable, Equatable, Sendable {
    case proposal(AgentAction)
    case reminder(Reminder)
    case output(AutomationOutputCard)

    package var id: InboxSelection {
        switch self {
        case let .proposal(action): .proposal(action.id)
        case let .reminder(reminder): .reminder(reminder.id)
        case let .output(card): .output(card.id)
        }
    }
}

/// One titled block of the Inbox list.
package struct InboxSection: Equatable, Sendable {
    package let title: String
    package let items: [InboxListItem]

    package init(title: String, items: [InboxListItem]) {
        self.title = title
        self.items = items
    }
}

/// The Inbox list (spec B1): agent proposals, then automation cards and due
/// reminders of today and of earlier days, newest first. A reminder sorts by
/// its due time. An empty section is left out.
package enum InboxListBuilder {
    package static func sections(
        proposals: [AgentAction],
        reminders: [Reminder],
        outputs: [AutomationOutputCard],
        now: Date,
        calendar: Calendar
    ) -> [InboxSection] {
        let dated = (outputs.map { (at: $0.createdAt, item: InboxListItem.output($0)) }
            + reminders.map { (at: AutomationDates.parse($0.remindAt) ?? .distantPast, item: .reminder($0)) })
            .sorted { $0.at > $1.at }
        let startOfToday = calendar.startOfDay(for: now)
        let sections = [
            InboxSection(title: "Needs your decision", items: proposals.map(InboxListItem.proposal)),
            InboxSection(title: "Today", items: dated.filter { $0.at >= startOfToday }.map(\.item)),
            InboxSection(title: "Earlier", items: dated.filter { $0.at < startOfToday }.map(\.item))
        ]
        return sections.filter { !$0.items.isEmpty }
    }
}

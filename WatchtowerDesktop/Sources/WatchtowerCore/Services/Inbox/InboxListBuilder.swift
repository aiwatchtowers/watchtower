import Foundation

/// One row of the Inbox list.
package enum InboxListItem: Identifiable, Equatable, Sendable {
    case proposal(AgentAction)
    case reminder(Reminder)
    case output(AutomationOutputCard)
    case day(InboxDayCard)
    case track(InboxTrackCard)
    case idea(Idea)
    case message(HomeFeedInboxRow)

    package var id: InboxSelection {
        switch self {
        case let .proposal(action): .proposal(action.id)
        case let .reminder(reminder): .reminder(reminder.id)
        case let .output(card): .output(card.id)
        case let .day(card): .day(card.date)
        case let .track(card): .track(card.track.id)
        case let .idea(idea): .idea(idea.id)
        case let .message(row): .message(row.item.id)
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

/// The Inbox list (spec B1, C1 §5): items that wait on the owner first, then
/// the dated cards of today and of earlier days, newest first. A reminder
/// sorts by its due time. An empty section is left out.
package enum InboxListBuilder {
    package static func sections(
        proposals: [AgentAction],
        reminders: [Reminder],
        outputs: [AutomationOutputCard],
        now: Date,
        calendar: Calendar
    ) -> [InboxSection] {
        sections(
            InboxFeedSnapshot(proposals: proposals, reminders: reminders, outputs: outputs),
            filter: .all, dayDone: nil, today: "", now: now, calendar: calendar
        )
    }

    /// `today` is the "YYYY-MM-DD" of `now`; `dayDone` the date whose day card
    /// the owner finished (it then sorts by time instead of staying pinned).
    package static func sections(
        _ feed: InboxFeedSnapshot,
        filter: InboxFilter,
        dayDone: String?,
        today: String,
        now: Date,
        calendar: Calendar
    ) -> [InboxSection] {
        let showsAll = filter == .all
        let showsProposals = showsAll || filter == .automations
        let showsAutomationCards = showsProposals
        let showsIdeas = showsAll || filter == .ideas

        let awaiting = showsProposals ? feed.proposals.map(InboxListItem.proposal) : []
        let awaitingIdeas = showsIdeas ? feed.ideas.filter(\.awaitsVerdict).map(InboxListItem.idea) : []

        var rows: [(at: Date, item: InboxListItem)] = []
        if showsAutomationCards {
            rows += feed.outputs.map { (at: $0.createdAt, item: .output($0)) }
            rows += feed.reminders.map { (at: AutomationDates.parse($0.remindAt) ?? .distantPast, item: .reminder($0)) }
        }
        if showsAll || filter == .day {
            let days = showsAll ? feed.days.filter { $0.date == today || $0.isUnread } : feed.days
            rows += days.map { (at: $0.stamp, item: .day($0)) }
        }
        if showsAll || filter == .tracks {
            let tracks = showsAll ? feed.tracks.filter(\.isUnread) : feed.tracks
            rows += tracks.map { (at: $0.lastEventAt, item: .track($0)) }
        }
        if showsAll || filter == .messages {
            rows += feed.messages.map { (at: $0.stamp, item: .message($0)) }
        }
        if filter == .ideas {
            rows += feed.ideas.filter { !$0.awaitsVerdict }
                .map { (at: AutomationDates.parse($0.updatedAt) ?? .distantPast, item: .idea($0)) }
        }
        rows.sort { lhs, rhs in
            lhs.at != rhs.at ? lhs.at > rhs.at : tieOrder(lhs.item) < tieOrder(rhs.item)
        }

        let startOfToday = calendar.startOfDay(for: now)
        // Today's day card stays on top until the owner marks it done.
        func isPinned(_ item: InboxListItem) -> Bool {
            guard case let .day(card) = item else { return false }
            return card.date == today && dayDone != today
        }
        func isToday(_ row: (at: Date, item: InboxListItem)) -> Bool {
            row.at >= startOfToday || isPinned(row.item)
        }
        let todayRows = rows.filter(isToday)
        let pinned = todayRows.filter { isPinned($0.item) }
        let rest = todayRows.filter { !isPinned($0.item) }
        let sections = [
            InboxSection(title: "Needs your decision", items: awaiting + awaitingIdeas),
            InboxSection(title: "Today", items: (pinned + rest).map(\.item)),
            InboxSection(title: "Earlier", items: rows.filter { !isToday($0) }.map(\.item))
        ]
        return sections.filter { !$0.items.isEmpty }
    }

    /// Equal times keep one order across refreshes: outputs, reminders, day
    /// cards, tracks, messages, ideas, then by id.
    private static func tieOrder(_ item: InboxListItem) -> TieKey {
        switch item {
        case let .output(card): TieKey(rank: 0, number: card.id)
        case let .reminder(reminder): TieKey(rank: 1, number: reminder.id)
        case let .day(card): TieKey(rank: 2, text: card.date)
        case let .track(card): TieKey(rank: 3, number: Int64(card.track.id))
        case let .message(row): TieKey(rank: 4, number: Int64(row.item.id))
        case let .idea(idea): TieKey(rank: 5, number: Int64(idea.id))
        case let .proposal(action): TieKey(rank: 6, number: action.id)
        }
    }

    private struct TieKey: Comparable {
        let rank: Int
        var number: Int64 = 0
        var text: String = ""

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.rank, lhs.number, lhs.text) < (rhs.rank, rhs.number, rhs.text)
        }
    }

    /// The row to open once `id` left the list (Done, Dismiss, Snooze): the
    /// one below it, or the one above when it was the last; nil when it was
    /// alone or is not listed.
    package static func selection(after id: InboxSelection, in sections: [InboxSection]) -> InboxSelection? {
        let ids = sections.flatMap(\.items).map(\.id)
        guard let index = ids.firstIndex(of: id) else { return nil }
        if index + 1 < ids.count { return ids[index + 1] }
        return index > 0 ? ids[index - 1] : nil
    }
}

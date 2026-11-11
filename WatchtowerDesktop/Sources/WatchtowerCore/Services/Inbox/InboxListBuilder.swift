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
    case builtinNotice(BuiltinUpgradeNotice)

    package var id: InboxSelection {
        switch self {
        case let .proposal(action): .proposal(action.id)
        case let .reminder(reminder): .reminder(reminder.id)
        case let .output(card): .output(card.id)
        case let .day(card): .day(card.date)
        case let .track(card): .track(card.track.id)
        case let .idea(idea): .idea(idea.id)
        case let .message(row): .message(row.item.id)
        case let .builtinNotice(notice): .builtinNotice(notice.builtinID)
        }
    }
}

/// One titled block of a legacy entry's list.
package struct InboxSection: Equatable, Sendable {
    package let title: String
    package let items: [InboxListItem]
    /// A fold the owner opens on demand (Track my threads' Stopped): its
    /// title shows even while `items` is empty (folded).
    package let foldable: Bool

    package init(title: String, items: [InboxListItem], foldable: Bool = false) {
        self.title = title
        self.items = items
        self.foldable = foldable
    }

    /// Track my threads' fold of stopped (dismissed) tracks.
    package static func stoppedTitle(_ count: Int) -> String { "Stopped · \(count)" }
}

/// The lists the root's legacy entries open (ask #445) and the root's day
/// cards. Since the filters went (inbox builder B), proposals, reminders and
/// automation cards are never listed here: they are Needs approval's and the
/// folders' own entries (`InboxFolderEntries`).
package enum InboxListBuilder {
    /// A legacy entry's list, newest first: ideas awaiting a verdict under
    /// Needs your decision (Idea finder), then Today and Earlier. An empty
    /// section is left out. Track my threads ends with a `Stopped · N` fold
    /// of the stopped tracks, listed only while `showsStopped`.
    package static func sections(
        _ feed: InboxFeedSnapshot,
        list: InboxLegacyList,
        now: Date,
        calendar: Calendar,
        showsStopped: Bool = false
    ) -> [InboxSection] {
        var decisions: [InboxListItem] = []
        var rows: [(at: Date, item: InboxListItem)] = []
        switch list {
        case .tracks:
            rows = feed.tracks.map { (at: $0.lastEventAt, item: .track($0)) }
        case .ideas:
            decisions = feed.ideas.filter(\.awaitsVerdict).map(InboxListItem.idea)
            rows = feed.ideas.filter { !$0.awaitsVerdict }
                .map { (at: AutomationDates.parse($0.updatedAt) ?? .distantPast, item: .idea($0)) }
        case .messages:
            rows = feed.messages.map { (at: $0.stamp, item: .message($0)) }
        }
        rows.sort { lhs, rhs in
            lhs.at != rhs.at ? lhs.at > rhs.at : tieOrder(lhs.item) < tieOrder(rhs.item)
        }
        let startOfToday = calendar.startOfDay(for: now)
        let sections = [
            InboxSection(title: "Needs your decision", items: decisions),
            InboxSection(title: "Today", items: rows.filter { $0.at >= startOfToday }.map(\.item)),
            InboxSection(title: "Earlier", items: rows.filter { $0.at < startOfToday }.map(\.item))
        ]
        var listed = sections.filter { !$0.items.isEmpty }
        if list == .tracks, !feed.stoppedTracks.isEmpty {
            listed.append(InboxSection(
                title: InboxSection.stoppedTitle(feed.stoppedTracks.count),
                items: showsStopped ? feed.stoppedTracks.map(InboxListItem.track) : [],
                foldable: true))
        }
        return listed
    }

    /// The root's one day card (the Morning brief entry, spec "One brief
    /// row"): today's; past days live inside it and on the Earlier line
    /// (`InboxRootSections.earlierLine`). Today with neither a briefing nor
    /// a plan gets a placeholder card (`InboxDayCard.placeholder`) while the
    /// owner is known (`feed.ownerKnown`; else the empty root carries
    /// OWNER-02) — never while the briefing and day-plan features are both
    /// off (`feed.briefingOn`, `feed.dayPlanOn`). `today` is the
    /// "YYYY-MM-DD" of `now`.
    package static func rootDays(_ feed: InboxFeedSnapshot, today: String, now: Date, calendar: Calendar) -> [InboxDayCard] {
        if let card = feed.days.first(where: { $0.date == today }) { return [card] }
        guard feed.briefingOn || feed.dayPlanOn, feed.ownerKnown else { return [] }
        return [.placeholder(date: today, stamp: calendar.startOfDay(for: now))]
    }

    /// Equal times keep one order across refreshes: tracks, messages, ideas,
    /// then by id (the other kinds are never among a legacy list's rows; their
    /// ranks only keep the switch exhaustive).
    private static func tieOrder(_ item: InboxListItem) -> TieKey {
        switch item {
        case let .output(card): TieKey(rank: 0, number: card.id)
        case let .reminder(reminder): TieKey(rank: 1, number: reminder.id)
        case let .day(card): TieKey(rank: 2, text: card.date)
        case let .track(card): TieKey(rank: 3, number: Int64(card.track.id))
        case let .message(row): TieKey(rank: 4, number: Int64(row.item.id))
        case let .idea(idea): TieKey(rank: 5, number: Int64(idea.id))
        case let .proposal(action): TieKey(rank: 6, number: action.id)
        case let .builtinNotice(notice): TieKey(rank: 7, text: notice.builtinID)
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

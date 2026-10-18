import Foundation

/// What a feed row is, in the order the kinds sit above NOW (the raw value).
package enum FeedKind: Int, Comparable, Sendable {
    case slack, jira, proposal, reminder, target, email

    package static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The source row behind a feed row or event; the key of a hide / done.
package enum FeedRef: Hashable, Sendable {
    case inbox(Int)
    case reminder(Int64)
    case proposal(Int64)
    case target(Int)
    case event(String)
}

/// What the owner can do to a row in place.
package enum FeedAction: Sendable {
    case done, hide
}

/// One row above NOW: something waiting on the owner.
package struct FeedRow: Equatable, Identifiable, Sendable {
    package let id: FeedRef
    package let kind: FeedKind
    /// "Mention", "DM", "Thread", "Reaction", "Jira", "Proposal", "Failed",
    /// "Reminder", "Overdue", "Due", "Email".
    package let chip: String
    package let who: String
    /// "#eng", an email subject, "assigned to you"; nil when there is none.
    package let whereText: String?
    package let text: String
    package let stamp: Date
    /// A read row renders secondary; it is never hidden by being read.
    package let read: Bool
    package let actions: Set<FeedAction>
    package let link: HomeLink

    package init(
        id: FeedRef,
        kind: FeedKind,
        chip: String,
        who: String,
        whereText: String?,
        text: String,
        stamp: Date,
        read: Bool,
        actions: Set<FeedAction>,
        link: HomeLink
    ) {
        self.id = id
        self.kind = kind
        self.chip = chip
        self.who = who
        self.whereText = whereText
        self.text = text
        self.stamp = stamp
        self.read = read
        self.actions = actions
        self.link = link
    }
}

/// One row below NOW: an event, a timed target or a later reminder.
package struct FeedEvent: Equatable, Identifiable, Sendable {
    package let id: FeedRef
    package let start: Date
    package let end: Date
    package let title: String
    /// "Meeting", "in N min", "until HH:mm", "Due", "Reminder".
    package let chip: String
    package let prepReady: Bool
    package let isNext: Bool
    package let isOngoing: Bool
    package let link: HomeLink

    package init(
        id: FeedRef,
        start: Date,
        end: Date,
        title: String,
        chip: String,
        prepReady: Bool,
        isNext: Bool,
        isOngoing: Bool,
        link: HomeLink
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.title = title
        self.chip = chip
        self.prepReady = prepReady
        self.isNext = isNext
        self.isOngoing = isOngoing
        self.link = link
    }
}

/// A feed source, for naming the ones whose read failed.
package enum FeedSource: Hashable, Sendable {
    case inbox, reminders, proposals, targets, calendar
}

/// The first later day with meetings.
package struct FeedDay: Equatable, Sendable {
    /// "Tomorrow", or the weekday ("Monday").
    package let title: String
    package let events: [FeedEvent]

    package init(title: String, events: [FeedEvent]) {
        self.title = title
        self.events = events
    }
}

/// Home's feed: what waits above NOW, the NOW line and what follows.
package struct HomeFeed: Equatable, Sendable {
    package let waiting: [FeedRow]
    /// Rows past the cap, behind "N more".
    package let hiddenWaiting: Int
    package let nowLabel: String
    package let ongoing: FeedEvent?
    package let laterToday: [FeedEvent]
    package let nextDay: FeedDay?
    /// A source whose read failed (logged); never an all-clear.
    package let failed: Set<FeedSource>

    package init(
        waiting: [FeedRow],
        hiddenWaiting: Int,
        nowLabel: String,
        ongoing: FeedEvent?,
        laterToday: [FeedEvent],
        nextDay: FeedDay?,
        failed: Set<FeedSource>
    ) {
        self.waiting = waiting
        self.hiddenWaiting = hiddenWaiting
        self.nowLabel = nowLabel
        self.ongoing = ongoing
        self.laterToday = laterToday
        self.nextDay = nextDay
        self.failed = failed
    }
}

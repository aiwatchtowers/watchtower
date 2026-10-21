import Foundation

/// The Inbox filter bar's segments (spec §5.1). Each one shows its own kinds
/// of card; `all` is the triage mix.
package enum InboxFilter: String, CaseIterable, Sendable {
    case all, day, messages, tracks, ideas, automations

    package var title: String {
        switch self {
        case .all: "All"
        case .day: "Day"
        case .messages: "Messages"
        case .tracks: "Tracks"
        case .ideas: "Ideas"
        case .automations: "Automations"
        }
    }

    /// The `EmptyStateCopyTable` key of the filter's empty list.
    package var emptyCopyKey: String {
        switch self {
        case .all: "inbox"
        case .day: "briefings"
        case .messages: "inboxMessages"
        case .tracks: "tracks"
        case .ideas: "ideas"
        case .automations: "inboxAutomations"
        }
    }
}

/// One day of the Day filter: the briefing and the day plan of one date.
package struct InboxDayCard: Equatable, Sendable {
    package let date: String // "YYYY-MM-DD"
    package let briefing: Briefing?
    package let plan: DayPlan?
    package let planDone: Int
    package let planTotal: Int
    /// The briefing's `created_at`, else the plan's `generated_at`.
    package let stamp: Date

    package init(date: String, briefing: Briefing?, plan: DayPlan?, planDone: Int, planTotal: Int, stamp: Date) {
        self.date = date
        self.briefing = briefing
        self.plan = plan
        self.planDone = planDone
        self.planTotal = planTotal
        self.stamp = stamp
    }

    package var isUnread: Bool { briefing.map { $0.readAt == nil } ?? false }
}

/// One track of the Tracks filter with its latest activity.
package struct InboxTrackCard: Equatable, Sendable {
    package let track: Track
    package let lastEventAt: Date
    package let newEventCount: Int

    package init(track: Track, lastEventAt: Date, newEventCount: Int) {
        self.track = track
        self.lastEventAt = lastEventAt
        self.newEventCount = newEventCount
    }

    package var isUnread: Bool { track.isUnread || newEventCount > 0 }
}

/// Everything the Inbox list can show, as one read left it.
package struct InboxFeedSnapshot: Equatable, Sendable {
    package var proposals: [AgentAction] = []
    package var reminders: [Reminder] = []
    package var outputs: [AutomationOutputCard] = []
    package var days: [InboxDayCard] = []
    package var tracks: [InboxTrackCard] = []
    package var ideas: [Idea] = []
    package var messages: [HomeFeedInboxRow] = []

    package init(
        proposals: [AgentAction] = [],
        reminders: [Reminder] = [],
        outputs: [AutomationOutputCard] = [],
        days: [InboxDayCard] = [],
        tracks: [InboxTrackCard] = [],
        ideas: [Idea] = [],
        messages: [HomeFeedInboxRow] = []
    ) {
        self.proposals = proposals
        self.reminders = reminders
        self.outputs = outputs
        self.days = days
        self.tracks = tracks
        self.ideas = ideas
        self.messages = messages
    }
}

package extension Idea {
    /// Waits on the owner's verdict: the predicate of `IdeaQueries.fetchForReview`.
    /// A decision is informational and never waits.
    var awaitsVerdict: Bool { isForReview && kind != .decision }
}

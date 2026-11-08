import Foundation

/// A legacy entry of the Inbox's root whose pane is today's list for it
/// (ask #445): Track my threads, Idea finder and Messages. The filter bar
/// that once chose these lists is gone (inbox builder B).
package enum InboxLegacyList: String, CaseIterable, Sendable {
    case tracks, ideas, messages

    /// The entry's and its list's title.
    package var title: String {
        switch self {
        case .tracks: "Track my threads"
        case .ideas: "Idea finder"
        case .messages: "Messages"
        }
    }

    /// The `EmptyStateCopyTable` key of the list when it has nothing.
    package var emptyCopyKey: String {
        switch self {
        case .tracks: "tracks"
        case .ideas: "ideas"
        case .messages: "inboxMessages"
        }
    }
}

/// One day of the Morning brief: the briefing and the day plan of one date.
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

    /// Today before its briefing and its plan exist: the list still shows the
    /// day's card, whose pane offers to make them. Never unread, so never in
    /// the badge.
    package static func placeholder(date: String, stamp: Date) -> Self {
        Self(date: date, briefing: nil, plan: nil, planDone: 0, planTotal: 0, stamp: stamp)
    }

    /// Neither a briefing nor a plan: the placeholder of `placeholder(date:stamp:)`.
    package var isEmpty: Bool { briefing == nil && plan == nil }
}

/// One track of Track my threads with its latest activity.
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
    /// `users` id → best name for the `person` blocks of `outputs`
    /// (`AutomationQueries.artifactPeople`).
    package var artifactPeople: [String: String] = [:]
    package var days: [InboxDayCard] = []
    /// More dates exist past `days` (a route to an old day reads more pages).
    package var hasOlderDays = false
    /// Watchtower knows the owner (OWNER-01). Without one, the root shows no
    /// placeholder day card, so the empty Inbox says why (OWNER-02).
    package var ownerKnown = true
    /// The briefing and day-plan features are on (Settings → Features). With
    /// both off the root shows no placeholder day card, and its pane
    /// offers to make only the halves still on.
    package var briefingOn = true
    package var dayPlanOn = true
    package var tracks: [InboxTrackCard] = []
    /// Dismissed tracks: only Track my threads' Stopped fold lists them,
    /// nothing counts them.
    package var stoppedTracks: [InboxTrackCard] = []
    package var ideas: [Idea] = []
    package var messages: [HomeFeedInboxRow] = []
    /// Built-ins whose one-time move to Automations failed (C2): first in
    /// Needs approval, each with **Retry**.
    package var builtinNotices: [BuiltinUpgradeNotice] = []

    package init(
        proposals: [AgentAction] = [],
        reminders: [Reminder] = [],
        outputs: [AutomationOutputCard] = [],
        days: [InboxDayCard] = [],
        tracks: [InboxTrackCard] = [],
        stoppedTracks: [InboxTrackCard] = [],
        ideas: [Idea] = [],
        messages: [HomeFeedInboxRow] = []
    ) {
        self.proposals = proposals
        self.reminders = reminders
        self.outputs = outputs
        self.days = days
        self.tracks = tracks
        self.stoppedTracks = stoppedTracks
        self.ideas = ideas
        self.messages = messages
    }
}

package extension Idea {
    /// Waits on the owner's verdict: the predicate of `IdeaQueries.fetchForReview`.
    /// A decision is informational and never waits — except a chat-born one,
    /// which is born proposed and needs the owner's approval.
    var awaitsVerdict: Bool { isForReview && (kind != .decision || chatBorn) }
}

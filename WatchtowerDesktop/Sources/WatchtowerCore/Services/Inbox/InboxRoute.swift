import Foundation

/// Where a link into the Inbox lands: a filter and, optionally, the card to
/// open there. Briefings, Day Plan, Tracks and Ideas were screens of their
/// own before the one Inbox (C1); their old names stay accepted as
/// `watchtower-nav://` hosts (an old chat answer, a card link) and open the
/// matching filter instead.
package struct InboxRoute: Equatable, Sendable {
    package let filter: InboxFilter
    package let selection: InboxSelection?

    package init(filter: InboxFilter, selection: InboxSelection? = nil) {
        self.filter = filter
        self.selection = selection
    }

    /// The old screen names a nav link may still carry, and the filter each opens.
    package static let aliasHosts: [String: InboxFilter] = [
        "briefings": .day, "dayPlan": .day, "day-plan": .day, "tracks": .tracks, "ideas": .ideas
    ]

    /// The route of an old screen name; nil for any other host. A Day host
    /// opens today's day card (`today` is "YYYY-MM-DD").
    package static func fromNavHost(_ host: String, today: String) -> Self? {
        guard let filter = aliasHosts[host] else { return nil }
        return Self(filter: filter, selection: filter == .day ? .day(today) : nil)
    }

    /// Where a feature's own Open goes (Home's Getting ready cards): the
    /// briefing and the day plan open today's day card, tracks and ideas
    /// their filter. nil for a feature that keeps a screen of its own.
    package static func forFeature(_ feature: ReadinessFeature, today: String) -> Self? {
        switch feature {
        case .briefing, .dayPlan: Self(filter: .day, selection: .day(today))
        case .tracks: Self(filter: .tracks)
        case .ideas: Self(filter: .ideas)
        case .slackSync, .digests, .streamDigests, .peopleCards, .memory, .inbox, .knowledgeIndex,
             .calendar, .jira, .linear: nil
        }
    }
}

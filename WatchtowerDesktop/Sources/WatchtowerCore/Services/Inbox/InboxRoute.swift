import Foundation

/// Where a link into the Inbox lands (inbox builder B): a folder and,
/// optionally, what to open there. Briefings, Day Plan, Tracks and Ideas
/// were screens of their own before the one Inbox (C1), then filters; their
/// old names stay accepted as `watchtower-nav://` hosts (an old chat answer,
/// a card link) and open the root's matching legacy entry instead.
package struct InboxRoute: Equatable, Sendable {
    /// What a route opens in its folder.
    package enum Entry: Equatable, Sendable {
        /// A card: the Inbox opens the folder or legacy list that lists it
        /// (`ActionStripViewModel.open(folder:select:)`).
        case card(InboxSelection)
        /// A legacy entry of the root, its list open.
        case legacy(InboxLegacyList)
    }

    /// The folder to open; nil = the folder that lists `entry`, else the
    /// root. A folder that no longer exists opens the root.
    package let folderID: Int64?
    package let entry: Entry?

    package init(folderID: Int64? = nil, entry: Entry? = nil) {
        self.folderID = folderID
        self.entry = entry
    }

    /// A card, in the folder that lists it.
    package static func card(_ selection: InboxSelection) -> Self {
        Self(entry: .card(selection))
    }

    /// A legacy entry of the root with its list open.
    package static func legacy(_ list: InboxLegacyList) -> Self {
        Self(entry: .legacy(list))
    }

    /// The old screen names a nav link may still carry.
    package static let aliasHosts: Set<String> = ["briefings", "dayPlan", "day-plan", "tracks", "ideas"]

    /// The route of an old screen name; nil for any other host. A day host
    /// opens today's Morning brief entry (`today` is "YYYY-MM-DD"); tracks
    /// and ideas their legacy entry.
    package static func fromNavHost(_ host: String, today: String) -> Self? {
        switch host {
        case "briefings", "dayPlan", "day-plan": .card(.day(today))
        case "tracks": .legacy(.tracks)
        case "ideas": .legacy(.ideas)
        default: nil
        }
    }

    /// Where a feature's own Open goes (Home's Getting ready cards): the
    /// briefing and the day plan open today's Morning brief entry, tracks
    /// and ideas their legacy entry. nil for a feature that keeps a screen
    /// of its own.
    package static func forFeature(_ feature: ReadinessFeature, today: String) -> Self? {
        switch feature {
        case .briefing, .dayPlan: .card(.day(today))
        case .tracks: .legacy(.tracks)
        case .ideas: .legacy(.ideas)
        case .slackSync, .digests, .streamDigests, .peopleCards, .memory, .inbox, .knowledgeIndex,
             .calendar, .jira, .linear: nil
        }
    }
}

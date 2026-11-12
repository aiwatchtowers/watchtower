import Foundation

/// What the Morning brief's pane puts where (spec "One brief row", the
/// mockup's order): the lead line, **Start here**, **Waiting on you** and
/// **Moved overnight**. The brief's row in the list previews the same lead.
/// Pure: it only picks from what the read already holds.
package enum InboxBriefLayout {
    /// How many items Start here, Waiting on you and Moved overnight show.
    package static let topCount = 3

    /// The brief's one line: the first attention item's text, else the
    /// first your-day item's text, else nil.
    package static func lead(_ briefing: Briefing) -> String? {
        briefing.parsedAttention.first?.text ?? briefing.parsedYourDay.first?.text
    }

    /// Start here: the first three attention items, in the brief's order.
    package static func startHere(_ briefing: Briefing) -> [AttentionItem] {
        Array(briefing.parsedAttention.prefix(topCount))
    }

    /// **Waiting on you**'s rows: the newest three open messages (the feed
    /// reads only open ones), whatever day they came.
    package static func waitingOnYou(_ messages: [HomeFeedInboxRow]) -> [HomeFeedInboxRow] {
        Array(messages.sorted { $0.stamp > $1.stamp }.prefix(topCount))
    }

    /// **Moved overnight**'s rows: up to three unread tracks, newest event
    /// first, whenever that event was.
    package static func movedOvernight(_ tracks: [InboxTrackCard]) -> [InboxTrackCard] {
        Array(tracks.filter(\.isUnread).sorted { $0.lastEventAt > $1.lastEventAt }.prefix(topCount))
    }
}

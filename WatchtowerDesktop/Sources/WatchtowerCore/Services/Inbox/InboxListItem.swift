import Foundation
import WatchtowerInterface

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
    package static func stoppedTitle(_ count: Int) -> String { TowerText.stopped(count) }
}

package extension InboxSection {
    /// The row to open once `id` left the list (Done, Dismiss, Snooze): the
    /// one below it, or the one above when it was the last; nil when it was
    /// alone or is not listed.
    static func selection(after id: InboxSelection, in sections: [InboxSection]) -> InboxSelection? {
        let ids = sections.flatMap(\.items).map(\.id)
        guard let index = ids.firstIndex(of: id) else { return nil }
        if index + 1 < ids.count { return ids[index + 1] }
        return index > 0 ? ids[index - 1] : nil
    }
}

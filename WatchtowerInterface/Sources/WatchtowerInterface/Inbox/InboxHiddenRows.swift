/// The phone's optimistic hide (mobile Inbox spec §7): a row or card whose
/// action answered `ok` leaves the screen at once and stays hidden until a
/// feed leaves it out (then it is forgotten), or until two feeds still hold
/// it, when the hub's state wins and it shows again. Never optimistic
/// success: only an `ok` hides, a refusal never does.
///
/// A key is a card id (`Card.id`) or a ref row's `InboxRefRowModel.key`.
public struct InboxHiddenRows: Equatable, Sendable {
    /// Each hidden key and how many feeds have still held it since.
    private var seen: [String: Int] = [:]

    /// Feeds that may still hold a hidden key before it shows again.
    static let maxFeeds = 2

    public init() {}

    public mutating func hideOnOK(_ key: String) {
        seen[key] = 0
    }

    public mutating func observe(feed: Feed) {
        for (key, count) in seen {
            let held = Self.holds(feed, key) ? count + 1 : nil
            seen[key] = held.flatMap { $0 < Self.maxFeeds ? $0 : nil }
        }
    }

    public func isHidden(_ key: String) -> Bool {
        seen[key] != nil
    }

    /// The feed still draws `key`: a card with that id, or an open ref row.
    private static func holds(_ feed: Feed, _ key: String) -> Bool {
        feed.cards.contains { card in
            card.id == key || card.refFacts.contains { $0.open && InboxRefRowModel.key($0) == key }
        }
    }
}

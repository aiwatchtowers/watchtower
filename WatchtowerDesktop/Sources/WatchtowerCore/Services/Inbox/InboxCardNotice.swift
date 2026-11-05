import Foundation

/// The rule for any card-level notice (spec "Notifications"): a card may be
/// announced only when its row is new or its content changed — exactly when
/// `changed_at` moves and `read_at` is cleared. A same-hash rewrite moves
/// only `written_at` and is never news. At most one notice per automation
/// per run, naming the count, so a living automation that rewrites 50 cards
/// never posts 50 notices. No notice is posted today; whatever posts one
/// later (sub-project B's folders) builds it here.
package struct InboxCardNotice: Equatable, Sendable {
    package let automationID: Int64
    package let automationName: String
    package let runID: Int64
    /// The cards of this automation and run that are new or changed.
    package let count: Int

    /// "Threads waiting for me: 3 cards changed".
    package var text: String {
        "\(automationName): \(count) \(count == 1 ? "card" : "cards") changed"
    }

    /// The notices for `cards` against the read before it (`previous`): one
    /// per automation and run among the cards that are new or whose
    /// `changedAt` or `contentHash` moved, in the order their first card
    /// appears in `cards`.
    package static func cards(
        changedIn cards: [AutomationOutputCard], previous: [AutomationOutputCard]
    ) -> [Self] {
        let before = Dictionary(previous.map { ($0.id, $0) }) { first, _ in first }
        let changed = cards.filter { card in
            guard let old = before[card.id] else { return true }
            return old.changedAt != card.changedAt || old.contentHash != card.contentHash
        }
        struct Key: Hashable {
            let automationID: Int64
            let runID: Int64
        }
        var order: [Key] = []
        var groups: [Key: [AutomationOutputCard]] = [:]
        for card in changed {
            let key = Key(automationID: card.automationID, runID: card.runID)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(card)
        }
        return order.compactMap { key in
            guard let group = groups[key], let first = group.first else { return nil }
            return Self(automationID: key.automationID, automationName: first.automationName,
                        runID: key.runID, count: group.count)
        }
    }
}

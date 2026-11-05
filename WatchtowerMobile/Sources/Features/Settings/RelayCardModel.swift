import Foundation

/// Settings → Macs' Relay card (relay client Phase 4 Task 7, mockup S01–S06, S41, S55): the account's state in
/// the mockup's words. Every text lives here and is asserted in `RelayCardModelTests`.
struct RelayCardModel: Equatable {
    struct Row: Equatable {
        let title: String
        /// Trailing; nil when the row carries no value.
        let value: String?
    }

    enum Action: Equatable {
        /// The subscription screen (Task 9).
        case openSubscription
        /// Read the account again.
        case retry
        /// Restore Purchases, then the subscription screen (Task 9 wires the push).
        case restore
    }

    static let relayTitle = "Relay"
    static let sectionTitle = "Relay"
    static let subscriptionTitle = "Subscription"
    static let macsTitle = "Macs on this subscription"
    static let notSubscribed = "Not subscribed"
    static let checking = "Checking…"
    static let unreachable = "Couldn't reach Relay."
    static let retry = "Retry"
    static let active = "Active"
    static let grace = "Active. Check your payment in the App Store."
    static let ended = "Ended"
    static let endedLine = "Your subscription ended."
    static let subscribe = "Subscribe"
    static let moved = "Moved"
    static let movedLine = "Your subscription moved to another iPhone."
    static let restore = "Restore Purchases"
    static let notConfirmed = "Not confirmed"
    static let notConfirmedLine = "Your purchase isn't confirmed yet."

    let rows: [Row]
    /// A sentence under the rows (the error, the warning, the unconfirmed purchase).
    let line: String?
    /// What the card offers; the row or the line opens `.openSubscription` when `actionTitle` is nil.
    let action: Action?
    /// The title of the link row that performs `action`; nil when the row or line itself does.
    let actionTitle: String?
    let toneUses: [ToneUse]

    /// nil on an unavailable relay: no card at all (a dark build shows nothing of Relay).
    /// `unconfirmedPurchase` (`center.unconfirmed != nil`) replaces the card of `.free` and `.unknown`: the other
    /// phases have their own answer.
    init?(availability: RelayAvailability, phase: RelayAccountCenter.Phase, unconfirmedPurchase: Bool, slotLimit: Int) {
        guard case .available = availability else { return nil }
        var line: String?
        var action: Action?
        var actionTitle: String?
        var lineTone = PhoneTone.secondary
        switch phase {
        case .checking:
            rows = [Row(title: Self.relayTitle, value: Self.checking)]
        case .unknown where !unconfirmedPurchase:
            rows = [Row(title: Self.relayTitle, value: nil)]
            line = Self.unreachable
            lineTone = .red
            action = .retry
            actionTitle = Self.retry
        case .free(ended: false) where !unconfirmedPurchase:
            rows = [Row(title: Self.relayTitle, value: Self.notSubscribed)]
            action = .openSubscription
        case .free where !unconfirmedPurchase:
            rows = [Row(title: Self.subscriptionTitle, value: Self.ended)]
            line = Self.endedLine
            action = .openSubscription
            actionTitle = Self.subscribe
        case .unknown, .free:
            rows = [Row(title: Self.subscriptionTitle, value: Self.notConfirmed)]
            line = Self.notConfirmedLine
            action = .openSubscription
        case let .paying(grace, macs):
            rows = [
                Row(title: Self.subscriptionTitle, value: Self.active),
                Row(title: Self.macsTitle, value: "\(macs.count) of \(slotLimit)")
            ]
            if grace { line = Self.grace }
        case .moved:
            rows = [Row(title: Self.subscriptionTitle, value: Self.moved)]
            line = Self.movedLine
            action = .restore
            actionTitle = Self.restore
        }
        self.line = line
        self.action = action
        self.actionTitle = actionTitle
        var uses = [ToneUse(element: "relay card rows", tone: .secondary, role: .info)]
        if line != nil { uses.append(ToneUse(element: "relay card line", tone: lineTone, role: .info)) }
        toneUses = uses
    }
}

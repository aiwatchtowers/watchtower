import Foundation
import WatchtowerHostedRelay

/// The Relay subscription screen (relay client Phase 4 Task 9, mockup S20–S29, S42–S46, S57): which frame shows for a press
/// and the account's state, in the mockup's words. Every text lives here and is asserted in `RelaySubscriptionModelTests`.
///
/// **What shows.** A running press wins. Then a paying phone is done (S29): the screen has nothing to sell. Then a purchase
/// the relay has not confirmed, over any state that would sell or say something false about it: **Subscribe** is not offered
/// during a period someone already paid for, and an owner already charged is not told "Nothing changed", "You weren't
/// charged" or "Waiting for approval". A press's own answer about the same thing (S26, S27, S28, S42, S43) and S29 keep
/// their frame. Then an app too old for the relay (S43), before Apple can charge: over the states whose press can lead to a
/// purchase only, because the latch stops a sale and does not rewrite an answer. Then the press's result.
struct RelaySubscriptionModel: Equatable {
    struct Button: Equatable {
        enum Action: Equatable {
            case subscribe
            /// `reloadProduct()`: S22, and S45 and S57 with no price.
            case reloadProduct
            /// `retryAccount()`, S46: the press that stopped at the account.
            case retryAccount
            /// `retryConfirm()`, S26.
            case retryConfirm
            case manageSubscription
            case done
        }

        let title: String
        /// nil: the frame's progress label, nothing to press.
        let action: Action?
    }

    static let screenTitle = "Relay"
    static let restoreTitle = "Restore Purchases"
    static let termsTitle = "Terms"
    static let privacyTitle = "Privacy"
    /// Apple's own page for the owner's subscriptions: this screen imports no StoreKit.
    static let manageSubscriptionPage = URL(string: "https://apps.apple.com/account/subscriptions")

    private static let leadLine = "Changes reach your phone in under a second instead of tens of seconds."
    private static let pitchBullets = [
        "Up to \(HostedRelayLimits.maxMacSlots) Macs on this iPhone",
        "Encrypted end to end: our server can't read anything",
        "Switch back to iCloud at any time"
    ]

    /// The frames that still sell have the lead and the bullets; a frame that answers one question does not.
    let lead: String?
    let bullets: [String]
    let primary: Button?
    let line: String?
    let lineIsError: Bool
    /// **Restore Purchases** can be pressed. While a press runs the link stays in place, dimmed (mockup S23).
    let showsRestore: Bool
    let restoreTone: PhoneTone
    let manageSubscriptionURL: URL?
    let termsURL: URL?
    let privacyURL: URL?
    let toneUses: [ToneUse]

    /// `product`: the center's last loaded one, for the frames with **Subscribe** that carry none of their own (S45, S57).
    /// Without it they offer **Load the Price** in S22's shape: no price is written in code. `updateRequired`: the center's latch.
    init(
        purchase: RelayAccountCenter.PurchaseState,
        unconfirmed: RelayAccountCenter.UnconfirmedPurchase?,
        phase: RelayAccountCenter.Phase,
        config: RelayConfig,
        product: RelayProduct? = nil,
        updateRequired: Bool = false
    ) {
        let shown = Self.shown(purchase, unconfirmed, phase, updateRequired: updateRequired)
        let frame = Self.frame(of: shown, product: product)
        lead = frame.sells ? Self.leadLine : nil
        bullets = frame.sells ? Self.pitchBullets : []
        primary = frame.primary
        line = frame.line
        lineIsError = frame.isError
        switch purchase {
        case .buying, .confirming, .restoring: showsRestore = false
        default: showsRestore = true
        }
        restoreTone = showsRestore ? .accent : .secondary
        manageSubscriptionURL = frame.primary?.action == .manageSubscription ? Self.manageSubscriptionPage : nil
        termsURL = config.termsURL
        privacyURL = config.privacyURL
        var uses = [
            ToneUse(element: "subscription links", tone: .accent, role: .info),
            ToneUse(element: "subscription restore", tone: restoreTone, role: .info)
        ]
        if frame.isError {
            uses.append(ToneUse(element: "subscription line", tone: .red, role: .info))
        }
        toneUses = uses
    }

    /// The view loads again on this while on screen (`.onChange(of: purchase)`). Never on the load's own writes.
    static func loadsProduct(on purchase: RelayAccountCenter.PurchaseState) -> Bool {
        purchase == .idle
    }

    private static func isPaying(_ phase: RelayAccountCenter.Phase) -> Bool {
        if case .paying = phase { return true }
        return false
    }

    /// The state whose frame shows: see "What shows" above.
    private static func shown(
        _ purchase: RelayAccountCenter.PurchaseState,
        _ unconfirmed: RelayAccountCenter.UnconfirmedPurchase?,
        _ phase: RelayAccountCenter.Phase,
        updateRequired: Bool
    ) -> RelayAccountCenter.PurchaseState {
        switch purchase {
        case .buying, .confirming, .restoring: return purchase
        default: break
        }
        if isPaying(phase) { return .done }
        guard let unconfirmed else {
            return updateRequired && canLeadToAPurchase(purchase) ? .updateRequired : purchase
        }
        switch purchase {
        case .idle, .loadingProduct, .productFailed, .ready, .storeFailed, .pending, .noSubscriptionFound, .accountFailed:
            switch unconfirmed {
            case .confirming: return .confirming
            case .notReached: return .boughtNotConfirmed
            case .refused: return .refused
            case .transferLimit: return .transferLimit
            case .notImplemented: return .notImplemented
            case .updateRequired: return .updateRequired
            }
        default:
            return purchase
        }
    }

    /// **Subscribe**, or a press on the way to it (a load, S46's **Try Again**). The rest are answers: `updateRequired` leaves them.
    private static func canLeadToAPurchase(_ purchase: RelayAccountCenter.PurchaseState) -> Bool {
        switch purchase {
        case .idle, .loadingProduct, .ready, .productFailed, .storeFailed, .noSubscriptionFound, .accountFailed: true
        default: false
        }
    }

    private struct Frame {
        var sells = false
        var primary: Button?
        var line: String?
        var isError = false
    }

    /// S45 and S57 with no price: a Restore ended there, so "Retry" would not say what the press does.
    private static let loadPrice = Button(title: "Load the Price", action: .reloadProduct)

    private static func frame(of state: RelayAccountCenter.PurchaseState, product: RelayProduct?) -> Frame {
        func subscribe(_ product: RelayProduct?) -> Button? {
            product.map { Button(title: "Subscribe — \($0.displayPrice) / month", action: .subscribe) }
        }
        func busy(_ title: String) -> Frame {
            Frame(sells: true, primary: Button(title: title, action: nil))
        }
        switch state {
        case .idle, .loadingProduct:
            return busy("Loading the price…")
        case .ready(let own):
            return Frame(sells: true, primary: subscribe(own))
        case .buying:
            return busy("Waiting for the App Store…")
        case .confirming:
            return busy("Confirming with Relay…")
        case .restoring:
            return busy("Restoring…")
        case .noSubscriptionFound:
            return Frame(
                sells: product != nil, primary: subscribe(product) ?? loadPrice, line: "No subscription found on this Apple ID."
            )
        case .storeFailed:
            return Frame(
                sells: product != nil, primary: subscribe(product) ?? loadPrice,
                line: "The App Store didn't finish. Nothing changed; you can try again.", isError: true
            )
        case .productFailed, .accountFailed, .pending, .boughtNotConfirmed, .refused, .transferLimit, .notImplemented,
             .updateRequired, .done:
            return answer(state)
        }
    }

    /// The frames that answer one question and sell nothing. The selling states never reach it.
    private static func answer(_ state: RelayAccountCenter.PurchaseState) -> Frame {
        func manage(_ line: String) -> Frame {
            Frame(primary: Button(title: "Manage Subscription", action: .manageSubscription), line: line, isError: true)
        }
        switch state {
        case .productFailed:
            return Frame(
                primary: Button(title: "Retry", action: .reloadProduct),
                line: "Couldn't load the subscription. Check your connection.", isError: true
            )
        case .accountFailed:
            return Frame(
                primary: Button(title: "Try Again", action: .retryAccount),
                line: "Couldn't reach Relay. You weren't charged.", isError: true
            )
        case .pending:
            return Frame(line: "Waiting for approval. Relay turns on when it's approved.")
        case .boughtNotConfirmed:
            return Frame(
                primary: Button(title: "Try Again", action: .retryConfirm),
                line: "You're subscribed. Relay turns on as soon as Watchtower reaches it."
            )
        case .refused:
            return manage("Relay couldn't confirm this purchase. Try Restore Purchases.")
        case .transferLimit:
            return manage("This subscription moved too many times this month. Try again later.")
        case .notImplemented:
            return manage("Relay can't take purchases right now. You're not charged again; try again later.")
        case .updateRequired:
            return Frame(line: "Update Watchtower from the App Store to use Relay.")
        case .done:
            return Frame(primary: Button(title: "Done", action: .done), line: "Relay is on. Choose it for each Mac in Macs.")
        default:
            return Frame()
        }
    }
}

/// A press on the Relay card, apart from the view; Now's banner (Task 10) restores the same way. Returns the work it started,
/// for a test to await.
@MainActor
enum RelaySubscriptionPress {
    @discardableResult
    static func card(_ action: RelayCardModel.Action, center: RelayAccountCenter?, open: () -> Void) -> Task<Void, Never>? {
        switch action {
        case .openSubscription:
            open()
            return nil
        case .retry:
            return Task { await center?.refresh() }
        case .restore:
            return restore(center: center, open: open)
        }
    }

    /// The restore starts and the screen opens at once, so its S44 and then its result show there. The product's load goes
    /// first: the restore takes over the state and the load only keeps the price, which S45 and S57 sell with.
    @discardableResult
    static func restore(center: RelayAccountCenter?, open: () -> Void) -> Task<Void, Never> {
        let load = Task { await center?.loadProduct() }
        let restore = Task { await center?.restore() }
        open()
        return Task {
            await load.value
            await restore.value
        }
    }
}

import Foundation
import XCTest
@testable import WatchtowerMobile

/// The subscription screen's every state (relay client Phase 4 Task 9, mockup S20–S29, S42–S46, S57): the mockup's exact
/// texts, what wins when a press and a background outcome disagree, and that **Subscribe** is never offered over a period
/// someone already paid for.
@MainActor
final class RelaySubscriptionModelTests: XCTestCase {
    private typealias Model = RelaySubscriptionModel
    private let price = RelayProduct(id: "relay", displayPrice: "$4.99")
    private let free = RelayAccountCenter.Phase.free(ended: false)
    private let lead = "Changes reach your phone in under a second instead of tens of seconds."
    private let bullets = [
        "Up to 3 Macs on this iPhone", "Encrypted end to end: our server can't read anything", "Switch back to iCloud at any time"
    ]
    private let subscribe = "Subscribe — $4.99 / month"
    private let manage = "Manage Subscription"
    private let refused = "Relay couldn't confirm this purchase. Try Restore Purchases."
    private let limit = "This subscription moved too many times this month. Try again later."
    private let noPurchases = "Relay can't take purchases right now. You're not charged again; try again later."
    private let tooOld = "Update Watchtower from the App Store to use Relay."
    private let notReached = "You're subscribed. Relay turns on as soon as Watchtower reaches it."
    private let relayIsOn = "Relay is on. Choose it for each Mac in Macs."

    private func model(
        _ purchase: RelayAccountCenter.PurchaseState,
        unconfirmed: RelayAccountCenter.UnconfirmedPurchase? = nil,
        phase: RelayAccountCenter.Phase? = nil,
        config: RelayConfig = RelayConfig(origin: nil),
        product: RelayProduct? = nil,
        updateRequired: Bool = false
    ) -> Model {
        Model(
            purchase: purchase, unconfirmed: unconfirmed, phase: phase ?? free, config: config, product: product,
            updateRequired: updateRequired
        )
    }

    func testEveryPurchaseStateHasItsCopy() {
        struct Case {
            let purchase: RelayAccountCenter.PurchaseState
            let primary: String?
            let action: Model.Button.Action?
            let line: String?
            var isError = false
            /// The frame keeps the lead and the bullets (mockup S20's shape).
            var pitches = false
        }
        let cases = [
            Case(purchase: .idle, primary: "Loading the price…", action: nil, line: nil, pitches: true),
            Case(purchase: .loadingProduct, primary: "Loading the price…", action: nil, line: nil, pitches: true),
            Case(purchase: .ready(price), primary: subscribe, action: .subscribe, line: nil, pitches: true),
            Case(
                purchase: .productFailed, primary: "Retry", action: .reloadProduct,
                line: "Couldn't load the subscription. Check your connection.", isError: true
            ),
            Case(purchase: .buying, primary: "Waiting for the App Store…", action: nil, line: nil, pitches: true),
            Case(purchase: .confirming, primary: "Confirming with Relay…", action: nil, line: nil, pitches: true),
            Case(purchase: .restoring, primary: "Restoring…", action: nil, line: nil, pitches: true),
            Case(
                purchase: .noSubscriptionFound, primary: subscribe, action: .subscribe,
                line: "No subscription found on this Apple ID.", pitches: true
            ),
            Case(
                purchase: .accountFailed, primary: "Try Again", action: .retryAccount,
                line: "Couldn't reach Relay. You weren't charged.", isError: true
            ),
            Case(purchase: .pending, primary: nil, action: nil, line: "Waiting for approval. Relay turns on when it's approved."),
            Case(purchase: .boughtNotConfirmed, primary: "Try Again", action: .retryConfirm, line: notReached),
            Case(purchase: .refused, primary: manage, action: .manageSubscription, line: refused, isError: true),
            Case(purchase: .transferLimit, primary: manage, action: .manageSubscription, line: limit, isError: true),
            Case(purchase: .notImplemented, primary: manage, action: .manageSubscription, line: noPurchases, isError: true),
            Case(purchase: .updateRequired, primary: nil, action: nil, line: tooOld),
            Case(
                purchase: .storeFailed, primary: subscribe, action: .subscribe,
                line: "The App Store didn't finish. Nothing changed; you can try again.", isError: true, pitches: true
            ),
            Case(purchase: .done, primary: "Done", action: .done, line: relayIsOn)
        ]
        for item in cases {
            let shown = model(item.purchase, product: price)
            let name = "\(item.purchase)"
            XCTAssertEqual(shown.primary?.title, item.primary, name)
            XCTAssertEqual(shown.primary?.action, item.action, name)
            XCTAssertEqual(shown.line, item.line, name)
            XCTAssertEqual(shown.lineIsError, item.isError, name)
            XCTAssertEqual(shown.lead, item.pitches ? lead : nil, name)
            XCTAssertEqual(shown.bullets, item.pitches ? bullets : [], name)
        }
        XCTAssertEqual(Model.screenTitle, "Relay")
        XCTAssertEqual(Model.restoreTitle, "Restore Purchases")
        XCTAssertEqual(Model.termsTitle, "Terms")
        XCTAssertEqual(Model.privacyTitle, "Privacy")
    }

    private func frames() -> [(RelayAccountCenter.UnconfirmedPurchase, String?, String?)] {
        [
            (.confirming, "Confirming with Relay…", nil),
            (.notReached, "Try Again", notReached),
            (.refused, manage, refused),
            (.transferLimit, manage, limit),
            (.notImplemented, manage, noPurchases),
            (.updateRequired, nil, tooOld)
        ]
    }

    func testAnUnconfirmedPurchaseOffersNoSubscribe() {
        for (unconfirmed, primary, line) in frames() {
            for purchase: RelayAccountCenter.PurchaseState in [.ready(price), .idle, .loadingProduct, .productFailed] {
                let shown = model(purchase, unconfirmed: unconfirmed)
                let name = "\(unconfirmed) over \(purchase)"
                XCTAssertEqual(shown.primary?.title, primary, name)
                XCTAssertEqual(shown.line, line, name)
                XCTAssertNotEqual(shown.primary?.action, .subscribe, name)
                XCTAssertTrue(shown.showsRestore, name)
            }
        }
    }

    func testNoUnconfirmedPurchaseOffersSubscribeAgain() {
        XCTAssertEqual(model(.ready(price)).primary?.title, subscribe)
        // A refusal that no longer holds: the row's period ended, the screen was closed, the product loaded again.
        var shown = model(.refused)
        XCTAssertEqual(shown.primary?.title, manage)
        shown = model(.ready(price), unconfirmed: nil, phase: .free(ended: true))
        XCTAssertEqual(shown.primary?.title, subscribe)
        XCTAssertEqual(shown.primary?.action, .subscribe)
        XCTAssertNil(shown.line)
    }

    func testAPressWinsOverTheBackgroundOutcome() {
        XCTAssertEqual(model(.buying, unconfirmed: .refused).primary?.title, "Waiting for the App Store…")
        XCTAssertEqual(model(.restoring, unconfirmed: .notReached).primary?.title, "Restoring…")
        XCTAssertEqual(model(.confirming, unconfirmed: .refused).primary?.title, "Confirming with Relay…")
        XCTAssertEqual(model(.transferLimit, unconfirmed: .refused).line, limit, "a definite answer about the same thing")
        XCTAssertEqual(model(.boughtNotConfirmed, unconfirmed: .refused).line, notReached)
        let paying = RelayAccountCenter.Phase.paying(grace: false, macs: [])
        XCTAssertEqual(model(.buying, phase: paying).primary?.title, "Waiting for the App Store…", "a running press beats paying too")
        XCTAssertEqual(model(.restoring, phase: paying).primary?.title, "Restoring…")
        XCTAssertEqual(model(.confirming, phase: paying).primary?.title, "Confirming with Relay…")
    }

    /// An owner already charged needs S26 or S27, not "Nothing changed".
    func testAnUnconfirmedPurchaseWinsOverAFailedStoreCall() {
        for (unconfirmed, primary, line) in frames() {
            let shown = model(.storeFailed, unconfirmed: unconfirmed, product: price)
            XCTAssertEqual(shown.primary?.title, primary, "\(unconfirmed)")
            XCTAssertEqual(shown.line, line, "\(unconfirmed)")
            XCTAssertTrue(shown.showsRestore, "\(unconfirmed)")
        }
    }

    /// Each of these says something false, or sells, over a period Apple already sold: "Waiting for approval" after the
    /// approval, **Subscribe** on "No subscription found", "You weren't charged" to a charged owner.
    func testAnUnconfirmedPurchaseWinsOverAResultThatWouldBeFalse() {
        for purchase: RelayAccountCenter.PurchaseState in [.pending, .noSubscriptionFound, .accountFailed] {
            for (unconfirmed, primary, line) in frames() {
                let shown = model(purchase, unconfirmed: unconfirmed, product: price)
                let name = "\(unconfirmed) over \(purchase)"
                XCTAssertEqual(shown.primary?.title, primary, name)
                XCTAssertEqual(shown.line, line, name)
                XCTAssertNotEqual(shown.primary?.action, .subscribe, name)
                XCTAssertNotEqual(shown.primary?.action, .retryAccount, name)
                XCTAssertTrue(shown.showsRestore, name)
            }
        }
    }

    /// The App Store charges before the submit could say the app is too old: S43 first, not after the money.
    func testAnAppTooOldSellsNothing() {
        let selling: [RelayAccountCenter.PurchaseState] = [.idle, .loadingProduct, .ready(price), .productFailed, .storeFailed, .noSubscriptionFound]
        for purchase in selling {
            let shown = model(purchase, product: price, updateRequired: true)
            XCTAssertEqual(shown.line, tooOld, "\(purchase)")
            XCTAssertNil(shown.primary, "\(purchase)")
            XCTAssertNil(shown.lead, "\(purchase)")
            XCTAssertNil(shown.manageSubscriptionURL, "\(purchase)")
            XCTAssertTrue(shown.showsRestore, "\(purchase)")
        }
        // A press in progress keeps its frame.
        XCTAssertEqual(model(.buying, updateRequired: true).primary?.title, "Waiting for the App Store…")
        XCTAssertEqual(model(.restoring, updateRequired: true).primary?.title, "Restoring…")
        XCTAssertEqual(model(.confirming, updateRequired: true).primary?.title, "Confirming with Relay…")
        // A purchase already made says what happened to it.
        XCTAssertEqual(model(.ready(price), unconfirmed: .notReached, updateRequired: true).line, notReached)
        XCTAssertEqual(model(.ready(price), unconfirmed: .refused, updateRequired: true).line, refused)
        // A paying phone has nothing to sell either way.
        let paying = RelayAccountCenter.Phase.paying(grace: false, macs: [])
        XCTAssertEqual(model(.ready(price), phase: paying, updateRequired: true).line, relayIsOn)
        // Without the latch it sells again.
        XCTAssertEqual(model(.ready(price)).primary?.title, subscribe)
    }

    func testAPayingPhoneIgnoresUnconfirmed() {
        for (unconfirmed, _, _) in frames() {
            let shown = model(.ready(price), unconfirmed: unconfirmed, phase: .paying(grace: false, macs: ["a"]))
            XCTAssertEqual(shown.line, relayIsOn, "\(unconfirmed)")
            XCTAssertEqual(shown.primary?.action, .done, "\(unconfirmed)")
        }
    }

    func testAPayingPhoneWithNoPressIsDone() {
        for grace in [false, true] {
            let paying = RelayAccountCenter.Phase.paying(grace: grace, macs: [])
            let states: [RelayAccountCenter.PurchaseState] = [
                .idle, .ready(price), .loadingProduct, .productFailed, .noSubscriptionFound, .storeFailed, .accountFailed, .refused, .done
            ]
            for purchase in states {
                let shown = model(purchase, phase: paying, product: price)
                XCTAssertEqual(shown.line, relayIsOn, "\(purchase)")
                XCTAssertEqual(shown.primary?.title, "Done", "\(purchase)")
                XCTAssertNil(shown.lead, "\(purchase)")
            }
        }
    }

    func testManageSubscriptionOnEveryDefiniteRefusal() throws {
        let url = try XCTUnwrap(URL(string: "https://apps.apple.com/account/subscriptions"))
        for purchase: RelayAccountCenter.PurchaseState in [.refused, .transferLimit, .notImplemented] {
            XCTAssertEqual(model(purchase).manageSubscriptionURL, url, "\(purchase)")
        }
        for unconfirmed: RelayAccountCenter.UnconfirmedPurchase in [.refused, .transferLimit, .notImplemented] {
            XCTAssertEqual(model(.ready(price), unconfirmed: unconfirmed).manageSubscriptionURL, url, "\(unconfirmed)")
        }
        let others: [RelayAccountCenter.PurchaseState] = [
            .idle, .loadingProduct, .productFailed, .ready(price), .buying, .confirming, .pending, .boughtNotConfirmed,
            .accountFailed, .restoring, .noSubscriptionFound, .updateRequired, .storeFailed, .done
        ]
        for purchase in others {
            XCTAssertNil(model(purchase).manageSubscriptionURL, "\(purchase)")
            XCTAssertNotEqual(model(purchase).primary?.action, .manageSubscription, "\(purchase)")
        }
        for unconfirmed: RelayAccountCenter.UnconfirmedPurchase in [.confirming, .notReached, .updateRequired] {
            XCTAssertNil(model(.ready(price), unconfirmed: unconfirmed).manageSubscriptionURL, "\(unconfirmed)")
        }
    }

    func testThePriceComesOnlyFromTheProduct() {
        let other = RelayProduct(id: "relay", displayPrice: "€1,23")
        XCTAssertEqual(model(.ready(other)).primary?.title, "Subscribe — €1,23 / month")
        XCTAssertEqual(model(.storeFailed, product: other).primary?.title, "Subscribe — €1,23 / month")
        XCTAssertEqual(model(.noSubscriptionFound, product: other).primary?.title, "Subscribe — €1,23 / month")
    }

    /// A Restore pressed before any load found a price: no **Subscribe** to write, so **Retry** as on S22, and S22's shape.
    func testAResultWithNoPriceOffersRetry() {
        let lines: [(RelayAccountCenter.PurchaseState, String, Bool)] = [
            (.noSubscriptionFound, "No subscription found on this Apple ID.", false),
            (.storeFailed, "The App Store didn't finish. Nothing changed; you can try again.", true)
        ]
        for (purchase, line, isError) in lines {
            let shown = model(purchase)
            XCTAssertEqual(shown.primary, Model.Button(title: "Retry", action: .reloadProduct), "\(purchase)")
            XCTAssertEqual(shown.line, line, "\(purchase)")
            XCTAssertEqual(shown.lineIsError, isError, "\(purchase)")
            XCTAssertNil(shown.lead, "\(purchase)")
            XCTAssertEqual(shown.bullets, [], "\(purchase)")
            XCTAssertTrue(shown.showsRestore, "\(purchase)")
        }
    }

    func testRestoreIsDisabledOnlyWhileABuyRuns() {
        let running: [RelayAccountCenter.PurchaseState] = [.buying, .confirming, .restoring]
        for purchase in running {
            XCTAssertFalse(model(purchase).showsRestore, "\(purchase)")
            XCTAssertEqual(model(purchase).restoreTone, .secondary, "\(purchase)")
        }
        let others: [RelayAccountCenter.PurchaseState] = [
            .idle, .loadingProduct, .productFailed, .ready(price), .pending, .boughtNotConfirmed, .accountFailed,
            .noSubscriptionFound, .refused, .transferLimit, .notImplemented, .updateRequired, .storeFailed, .done
        ]
        for purchase in others {
            XCTAssertTrue(model(purchase).showsRestore, "\(purchase)")
            XCTAssertEqual(model(purchase).restoreTone, .accent, "\(purchase)")
        }
    }

    func testMissingLinksAreHidden() throws {
        let terms = try XCTUnwrap(URL(string: "https://example.com/terms"))
        let privacy = try XCTUnwrap(URL(string: "https://example.com/privacy"))
        let neither = model(.ready(price))
        XCTAssertNil(neither.termsURL)
        XCTAssertNil(neither.privacyURL)
        let both = model(.ready(price), config: RelayConfig(origin: nil, termsURL: terms, privacyURL: privacy))
        XCTAssertEqual(both.termsURL, terms)
        XCTAssertEqual(both.privacyURL, privacy)
        let one = model(.ready(price), config: RelayConfig(origin: nil, termsURL: terms))
        XCTAssertEqual(one.termsURL, terms)
        XCTAssertNil(one.privacyURL)
    }

    func testAnEmptyProductIsTheRetryState() async {
        let bed = AccountBed()
        let center = bed.makeCenter()
        bed.store.productResult = nil
        await center.loadProduct()
        let shown = model(center.purchase, unconfirmed: center.unconfirmed, phase: center.phase, product: center.product)
        XCTAssertEqual(shown.line, "Couldn't load the subscription. Check your connection.")
        XCTAssertEqual(shown.primary?.title, "Retry")
        XCTAssertEqual(shown.primary?.action, .reloadProduct)
        XCTAssertTrue(shown.lineIsError)

        bed.store.productResult = price
        await center.loadProduct()
        XCTAssertEqual(center.product, price)
        XCTAssertEqual(model(center.purchase, phase: center.phase).primary?.title, subscribe)
    }

    func testDoneNamesTheNextStep() {
        XCTAssertEqual(model(.done).line, "Relay is on. Choose it for each Mac in Macs.")
        XCTAssertEqual(model(.done).primary, Model.Button(title: "Done", action: .done))
        XCTAssertFalse(model(.done).lineIsError)
    }

    /// The view loads on `.idle` only: a result's frame stays, and the load's own write never re-triggers it.
    func testOnlyAnIdlePurchaseLoadsAgain() {
        XCTAssertTrue(Model.loadsProduct(on: .idle))
        let others: [RelayAccountCenter.PurchaseState] = [
            .loadingProduct, .productFailed, .ready(price), .buying, .confirming, .pending, .boughtNotConfirmed, .accountFailed,
            .restoring, .noSubscriptionFound, .refused, .transferLimit, .notImplemented, .updateRequired, .storeFailed, .done
        ]
        for purchase in others {
            XCTAssertFalse(Model.loadsProduct(on: purchase), "\(purchase)")
        }
    }

    func testTonesAreDeclared() {
        let states: [RelayAccountCenter.PurchaseState] = [
            .idle, .loadingProduct, .productFailed, .ready(price), .buying, .confirming, .pending, .boughtNotConfirmed,
            .accountFailed, .restoring, .noSubscriptionFound, .refused, .transferLimit, .notImplemented, .updateRequired,
            .storeFailed, .done
        ]
        for purchase in states {
            let shown = model(purchase, product: price)
            XCTAssertTrue(shown.toneUses.allSatisfy { $0.tone != .orange }, "\(purchase)")
            XCTAssertTrue(shown.toneUses.contains { $0.element == "subscription links" && $0.tone == .accent }, "\(purchase)")
            XCTAssertTrue(shown.toneUses.contains { $0.element == "subscription restore" && $0.tone == shown.restoreTone }, "\(purchase)")
            let line = shown.toneUses.first { $0.element == "subscription line" }
            XCTAssertEqual(line?.tone, shown.lineIsError ? .red : nil, "\(purchase)")
        }
    }
}

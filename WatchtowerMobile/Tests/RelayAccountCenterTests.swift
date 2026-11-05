import Foundation
import WatchtowerHostedRelay
import WatchtowerRelayProto
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// `RelayAccountCenter` (relay client Phase 4 Task 6), `FakeSubscriptionStore` over `FakeHostedRelay`: a purchase
/// survives anything between Apple and the relay, and a lapse or a move strands no Mac.
@MainActor
final class RelayAccountCenterTests: XCTestCase {
    private typealias Purchase = RelayAccountCenter.PurchaseState
    private typealias Unconfirmed = RelayAccountCenter.UnconfirmedPurchase

    /// A way the relay refuses the next submit.
    private enum Refusal: CaseIterable {
        case invalid, transferLimit, notImplemented, attestationUpdate

        func arm(on bed: AccountBed) {
            switch self {
            case .invalid: bed.fake.failNext("submitTransaction", with: .invalidTransaction)
            case .transferLimit: bed.fake.failNext("submitTransaction", with: .transferLimit)
            case .notImplemented: bed.fake.billingConfigured = false
            case .attestationUpdate: bed.fake.failNext("submitTransaction", with: .attestationFailed)
            }
        }

        func disarm(on bed: AccountBed) {
            if self == .notImplemented { bed.fake.billingConfigured = true }
        }

        var purchase: Purchase {
            switch self {
            case .invalid: .refused
            case .transferLimit: .transferLimit
            case .notImplemented: .notImplemented
            case .attestationUpdate: .updateRequired
            }
        }

        var unconfirmed: Unconfirmed {
            switch self {
            case .invalid: .refused
            case .transferLimit: .transferLimit
            case .notImplemented: .notImplemented
            case .attestationUpdate: .updateRequired
            }
        }
    }

    private func registeredBed() async throws -> (AccountBed, UUID) {
        let bed = AccountBed()
        let token = try await bed.register()
        return (bed, token)
    }

    private func started(_ bed: AccountBed) async -> RelayAccountCenter {
        let center = bed.makeCenter()
        center.start()
        await center.foreground()?.value
        return center
    }

    /// The next foreground's pass, a minute later.
    private func foreground(_ center: RelayAccountCenter, _ bed: AccountBed) async {
        bed.clock.advance(by: .seconds(61))
        await center.foreground()?.value
    }

    private func paying(_ bed: AccountBed, _ token: UUID, state: String = "active") async throws {
        try await bed.fake.setEntitlement(accountID: token.uuidString.lowercased(), state: state, for: .seconds(86_400 * 30))
    }

    // MARK: - Purchase

    func testABuyUsesTheAccountIDAsToken() async throws {
        let (bed, token) = try await registeredBed()
        bed.store.purchaseResult = .pending
        let center = await started(bed)
        await center.buy()
        XCTAssertEqual(bed.store.accountTokens, [token])
    }

    func testAPurchaseIsSubmittedThenFinishedThenRead() async throws {
        let (bed, token) = try await registeredBed()
        let center = await started(bed)
        let row = bed.row(token: token)
        bed.sell(row)
        let already = bed.ops.count
        let fake = bed.fake
        let atFinish = Captured<[String]>([])
        bed.store.onFinish = { atFinish.set(fake.log.map(FakeHostedRelay.name)) }

        await center.buy()

        XCTAssertEqual(Array(atFinish.value.dropFirst(already)), ["submitTransaction"], "finished after the submit, before the read")
        XCTAssertEqual(Array(bed.ops.dropFirst(already)), ["submitTransaction", "getAccountState"])
        XCTAssertEqual(bed.store.finished, [row])
        XCTAssertEqual(center.purchase, .done)
        XCTAssertEqual(center.phase, .paying(grace: false, macs: []))
        XCTAssertNil(center.unconfirmed)
    }

    func testAKilledPurchaseIsSubmittedAtTheNextLaunch() async throws {
        let (bed, token) = try await registeredBed()
        let row = bed.row(token: token)
        bed.store.unfinishedResult = [row]
        bed.http.hold(row.jws)
        let center = bed.makeCenter()
        center.start()
        center.foreground()
        try await bed.until("the submit in flight") { bed.http.isHolding(row.jws) }
        XCTAssertEqual(center.unconfirmed, .confirming, "the owner is told while it is confirmed")
        XCTAssertEqual(center.purchase, .idle)

        bed.http.release(row.jws)
        await center.passTask?.value

        XCTAssertEqual(bed.submitted, [row.jws])
        XCTAssertEqual(bed.store.finished, [row])
        XCTAssertNil(center.unconfirmed)
        XCTAssertEqual(center.phase, .paying(grace: false, macs: []))
    }

    func testAnUnreachableRelayLeavesTheTransactionUnfinished() async throws {
        let (bed, token) = try await registeredBed()
        let center = await started(bed)
        bed.sell(bed.row(token: token))
        bed.fake.crash()

        await center.buy()

        XCTAssertEqual(center.purchase, .boughtNotConfirmed)
        XCTAssertEqual(center.unconfirmed, .notReached)
        XCTAssertEqual(center.phase, .unknown, "a failed read is never free")
        XCTAssertEqual(bed.store.finished, [])

        bed.fake.restart()
        await center.retryConfirm()

        XCTAssertEqual(bed.store.finished.count, 1)
        XCTAssertEqual(center.purchase, .done)
        XCTAssertNil(center.unconfirmed)
    }

    func testEveryRefusalLeavesTheTransactionUnfinishedAndIsTriedAgain() async throws {
        for refusal in [Refusal.invalid, .transferLimit, .notImplemented] {
            let (bed, token) = try await registeredBed()
            let center = await started(bed)
            bed.sell(bed.row(token: token))
            refusal.arm(on: bed)

            await center.buy()

            XCTAssertEqual(center.purchase, refusal.purchase, "\(refusal)")
            XCTAssertEqual(center.unconfirmed, refusal.unconfirmed, "\(refusal)")
            XCTAssertEqual(bed.store.finished, [], "\(refusal)")
            XCTAssertEqual(bed.store.unfinishedResult.count, 1, "\(refusal): the row stays")

            refusal.disarm(on: bed)
            bed.clock.advance(by: .seconds(1))
            let again = bed.row(token: token)
            bed.store.restoreResult = again
            await center.restore()

            XCTAssertEqual(bed.store.finished, [again], "\(refusal): a later entitlement answer finishes it")
            XCTAssertEqual(center.purchase, .done, "\(refusal)")
            XCTAssertNil(center.unconfirmed, "\(refusal)")
        }
    }

    func testARefusedTransactionIsSentOncePerLaunch() async throws {
        let (bed, token) = try await registeredBed()
        bed.store.unfinishedResult = [bed.row(token: token)]
        bed.fake.failNext("submitTransaction", with: .invalidTransaction, times: 2)

        let center = await started(bed)
        XCTAssertEqual(bed.submitted.count, 1)
        await foreground(center, bed)
        await foreground(center, bed)
        XCTAssertEqual(bed.submitted.count, 1, "the bound: no second send in this process")

        _ = await started(bed)
        XCTAssertEqual(bed.submitted.count, 2, "the next launch sends it once")
    }

    func testAStaleUnfinishedMoveIsRefusedAndRestorePasses() async throws {
        let (bed, token) = try await registeredBed()
        let oldPhone = try await bed.otherPhone(seed: 0x41)
        let oldAccount = try await bed.fake.accountID(ofPhone: oldPhone.deviceID)
        let oldToken = try XCTUnwrap(UUID(uuidString: oldAccount))
        var first = Relay_V1_SubmitTransaction()
        first.signedTransaction = bed.row(token: oldToken).jws
        _ = try await oldPhone.submitTransaction(first)
        bed.clock.advance(by: .seconds(20 * 60))
        // Signed after the old phone's last submit, past the 10-minute window.
        let stale = bed.row(token: oldToken, signedAgo: 15 * 60)
        bed.store.unfinishedResult = [stale]

        let center = await started(bed)

        XCTAssertEqual(bed.submitted.last, stale.jws)
        XCTAssertEqual(center.unconfirmed, .refused)
        XCTAssertEqual(bed.store.finished, [])
        XCTAssertNotEqual(token, oldToken)

        let fresh = bed.row(token: oldToken)
        bed.store.restoreResult = fresh
        await center.restore()

        XCTAssertEqual(bed.submitted.last, fresh.jws)
        XCTAssertEqual(center.purchase, .done)
        XCTAssertEqual(center.phase, .paying(grace: false, macs: []))
        XCTAssertNil(center.unconfirmed)
    }

    func testAnOwnerPressIsNotBoundByTheRefusedSet() async throws {
        for press in ["restore", "retryConfirm"] {
            let (bed, token) = try await registeredBed()
            let old = bed.row(token: token)
            bed.store.unfinishedResult = [old]
            bed.fake.failNext("submitTransaction", with: .invalidTransaction)
            let center = await started(bed)
            XCTAssertEqual(center.unconfirmed, .refused, press)

            bed.clock.advance(by: .seconds(1))
            let fresh = bed.row(token: token)
            XCTAssertNotEqual(old.jws, fresh.jws)
            bed.store.unfinishedResult = [fresh]
            bed.store.restoreResult = fresh
            if press == "restore" { await center.restore() } else { await center.retryConfirm() }

            XCTAssertEqual(bed.submitted, [old.jws, fresh.jws], press)
            XCTAssertEqual(bed.store.finished, [fresh], press)
            XCTAssertEqual(center.purchase, .done, press)
            XCTAssertNil(center.unconfirmed, press)
        }
    }

    /// **Try Again** with no row left: the read decides, and an expired row is not sent.
    func testATryAgainWithNoRowLeftReadsTheAccount() async throws {
        let (bed, token) = try await registeredBed()
        bed.store.productResult = RelayProduct(id: "relay", displayPrice: "$4.99")
        let center = await started(bed)
        await center.loadProduct()
        bed.store.unfinishedResult = [bed.row(token: token, expiresIn: -1)]
        await center.retryConfirm()
        XCTAssertEqual(center.purchase, .ready(RelayProduct(id: "relay", displayPrice: "$4.99")))
        XCTAssertEqual(bed.submitted, [])

        try await paying(bed, token)
        await center.retryConfirm()
        XCTAssertEqual(center.purchase, .done)
    }

    /// A refused press whose own read says paying: S29, and the row stays for the next launch.
    func testARefusedPressWhoseReadSaysPayingIsDoneAndKeepsTheRow() async throws {
        let (bed, token) = try await registeredBed()
        try await paying(bed, token)
        let center = await started(bed)
        let row = bed.row(token: token)
        bed.sell(row)
        bed.fake.failNext("submitTransaction", with: .invalidTransaction)

        await center.buy()

        XCTAssertEqual(center.purchase, .done)
        XCTAssertEqual(center.unconfirmed, .refused)
        XCTAssertEqual(bed.store.finished, [], "a read never finishes a row")
        XCTAssertEqual(bed.store.unfinishedResult, [row])
    }

    func testAPressRefusedAgainKeepsTheAutomaticBound() async throws {
        let (bed, token) = try await registeredBed()
        let row = bed.row(token: token)
        bed.store.unfinishedResult = [row]
        bed.fake.failNext("submitTransaction", with: .invalidTransaction, times: 2)
        let center = await started(bed)

        await center.retryConfirm()
        XCTAssertEqual(center.purchase, .refused)
        XCTAssertEqual(bed.submitted.count, 2, "the press sends past the set")

        await foreground(center, bed)
        XCTAssertEqual(bed.submitted.count, 2, "the id stays in the set")
        XCTAssertEqual(center.unconfirmed, .refused)
    }

    func testARefusalAtLaunchIsShownAndSurvivesLoadProduct() async throws {
        for refusal in Refusal.allCases {
            let (bed, token) = try await registeredBed()
            bed.store.unfinishedResult = [bed.row(token: token)]
            bed.store.productResult = RelayProduct(id: "relay", displayPrice: "$4.99")
            refusal.arm(on: bed)

            let center = await started(bed)
            XCTAssertEqual(center.unconfirmed, refusal.unconfirmed, "\(refusal)")
            XCTAssertEqual(center.purchase, .idle, "\(refusal): a background pass writes no press state")

            await center.loadProduct()
            XCTAssertEqual(center.unconfirmed, refusal.unconfirmed, "\(refusal)")
            XCTAssertEqual(center.purchase, .ready(RelayProduct(id: "relay", displayPrice: "$4.99")), "\(refusal)")
        }
    }

    func testAnUnreachableRelayAtLaunchIsNotReached() async throws {
        let (bed, token) = try await registeredBed()
        bed.store.unfinishedResult = [bed.row(token: token)]
        bed.fake.crash()

        let center = await started(bed)
        XCTAssertEqual(center.unconfirmed, .notReached)
        XCTAssertEqual(center.purchase, .idle)
        XCTAssertEqual(center.phase, .unknown)

        bed.fake.restart()
        await center.retryConfirm()
        XCTAssertEqual(bed.store.finished.count, 1)
        XCTAssertNil(center.unconfirmed)
        XCTAssertEqual(center.purchase, .done)
    }

    /// A raw error from `submit` (an internal `.server(.unspecified)` in a 200) is like an unreachable relay.
    func testARawSubmitErrorIsNotARefusal() async throws {
        let (bed, token) = try await registeredBed()
        let row = bed.row(token: token)
        bed.store.unfinishedResult = [row]
        bed.fake.failNext("submitTransaction", with: .unspecified)

        let center = await started(bed)
        XCTAssertEqual(center.unconfirmed, .notReached)
        XCTAssertEqual(bed.store.finished, [])
        XCTAssertEqual(bed.submitted.count, 1)

        await foreground(center, bed)
        XCTAssertEqual(bed.submitted.count, 2, "not in the refused set: the sweep sends it again")
        XCTAssertEqual(bed.store.finished, [row])
        XCTAssertNil(center.unconfirmed)
    }

    func testAnEntitlementAnswerClearsTheUnconfirmedPurchase() async throws {
        for path in ["sweep", "restore"] {
            let (bed, token) = try await registeredBed()
            bed.store.unfinishedResult = [bed.row(token: token)]
            bed.fake.failNext("submitTransaction", with: .unspecified)
            let center = await started(bed)
            XCTAssertEqual(center.unconfirmed, .notReached, path)

            if path == "sweep" {
                await foreground(center, bed)
            } else {
                bed.store.restoreResult = bed.store.unfinishedResult.first
                await center.restore()
            }

            XCTAssertNil(center.unconfirmed, path)
            XCTAssertEqual(bed.store.finished.count, 1, path)
            XCTAssertEqual(bed.store.unfinishedResult, [], path)
        }
    }

    func testAnInactiveAnswerIsARefusal() async throws {
        for answer in [Relay_V1_EntitlementKind.none, .expired, .revoked] {
            let (bed, token) = try await registeredBed()
            let center = await started(bed)
            bed.sell(bed.row(token: token))
            bed.http.answerNextSubmit(answer)

            await center.buy()

            XCTAssertEqual(bed.store.finished, [], "\(answer)")
            XCTAssertEqual(center.purchase, .refused, "\(answer)")
            XCTAssertEqual(center.unconfirmed, .refused, "\(answer)")

            // In the refused set: a later sweep does not send it.
            let sent = bed.ops.count
            await foreground(center, bed)
            XCTAssertEqual(Array(bed.ops.dropFirst(sent)), ["getAccountState"], "\(answer)")
        }
    }

    func testASweepNeverTouchesThePurchaseState() async throws {
        let product = RelayProduct(id: "relay", displayPrice: "$4.99")
        for start in ["buying", "confirming", "ready", "done"] {
            let (bed, token) = try await registeredBed()
            bed.store.productResult = product
            let center = await started(bed)
            let press: Task<Void, Never>?
            let bought = bed.row(id: 1, token: token)
            switch start {
            case "buying":
                bed.store.purchaseResult = .pending
                bed.store.parkPurchase()
                press = Task { await center.buy() }
                try await bed.until("the sheet") { bed.store.purchaseIsParked }
                XCTAssertEqual(center.purchase, .buying)
            case "confirming":
                bed.sell(bought)
                bed.http.hold(bought.jws)
                press = Task { await center.buy() }
                try await bed.until("the submit") { bed.http.isHolding(bought.jws) }
                XCTAssertEqual(center.purchase, .confirming)
            case "ready":
                await center.loadProduct()
                press = nil
            default:
                bed.sell(bought)
                await center.buy()
                XCTAssertEqual(center.purchase, .done)
                press = nil
            }
            let before = center.purchase

            // A background pass submits another row, and is refused.
            let other = bed.row(id: 2, original: "2000", token: token)
            bed.store.unfinishedResult = [other]
            bed.fake.failNext("submitTransaction", with: .invalidTransaction)
            await foreground(center, bed)

            XCTAssertTrue(bed.submitted.contains(other.jws), start)
            XCTAssertEqual(center.purchase, before, start)

            bed.store.releasePurchase()
            bed.http.release(bought.jws)
            await press?.value
        }
    }

    func testAnExpiredRowIsNotSentAndSetsNothing() async throws {
        let (bed, token) = try await registeredBed()
        let row = bed.row(token: token, expiresIn: -1)
        bed.store.unfinishedResult = [row]
        let center = await started(bed)
        XCTAssertEqual(bed.submitted, [])
        XCTAssertNil(center.unconfirmed)
        XCTAssertEqual(bed.store.finished, [], "finishing is only ever an entitlement answer")
        XCTAssertEqual(bed.store.unfinishedResult, [row])
    }

    func testAPermanentRefusalEndsWithThePeriod() async throws {
        let (bed, token) = try await registeredBed()
        bed.store.unfinishedResult = [bed.row(token: token, expiresIn: 3_600)]
        bed.fake.failNext("submitTransaction", with: .invalidTransaction)
        let center = await started(bed)
        XCTAssertEqual(center.unconfirmed, .refused)

        bed.clock.advance(by: .seconds(3_601))
        await center.foreground()?.value

        XCTAssertNil(center.unconfirmed, "Subscribe returns")
        XCTAssertEqual(bed.submitted.count, 1)
        XCTAssertEqual(bed.store.finished, [])
    }

    func testARevokedRowClearsAtOnce() async throws {
        let (bed, token) = try await registeredBed()
        let row = bed.row(token: token)
        bed.store.unfinishedResult = [row]
        bed.fake.failNext("submitTransaction", with: .invalidTransaction)
        let center = await started(bed)
        XCTAssertEqual(center.unconfirmed, .refused)
        let reads = bed.reads

        bed.store.emit(bed.row(token: token, revoked: true))

        try await bed.until("cleared") { center.unconfirmed == nil }
        try await bed.until("the read decides the phase") { bed.reads > reads }
        XCTAssertEqual(bed.submitted.count, 1, "a revoked row is not sent")
        XCTAssertEqual(bed.store.finished, [])
    }

    func testAPressJoiningASweepSendsItsOwnJWSAfterARefusal() async throws {
        let (bed, token) = try await registeredBed()
        let center = await started(bed)
        let old = bed.row(token: token)
        bed.store.unfinishedResult = [old]
        bed.http.hold(old.jws)
        bed.fake.failNext("submitTransaction", with: .invalidTransaction)
        bed.clock.advance(by: .seconds(61))
        let sweep = center.foreground()
        try await bed.until("the sweep's submit") { bed.http.isHolding(old.jws) }

        let fresh = bed.row(token: token, signedAgo: -1)
        bed.store.restoreResult = fresh
        let press = Task { await center.restore() }
        try await bed.until("the press joined") { center.purchase == .restoring && bed.store.restoreCalls == 1 }
        await Task.yield()
        XCTAssertEqual(bed.submitted, [], "one flight")

        bed.http.release(old.jws)
        await press.value
        await sweep?.value

        XCTAssertEqual(bed.submitted, [old.jws, fresh.jws], "the refused flight, then the press's own")
        XCTAssertEqual(center.purchase, .done)
        XCTAssertEqual(bed.store.finished, [fresh])
    }

    func testASweepWithOneCurrentRowKeepsItThroughTheBound() async throws {
        let (bed, token) = try await registeredBed()
        bed.store.unfinishedResult = [bed.row(token: token)]
        bed.fake.failNext("submitTransaction", with: .transferLimit)
        let center = await started(bed)
        XCTAssertEqual(center.unconfirmed, .transferLimit)

        await foreground(center, bed)

        XCTAssertEqual(center.unconfirmed, .transferLimit, "skipping the id leaves it")
        XCTAssertEqual(bed.submitted.count, 1)
    }

    /// The v1 limit: the first purchase's row expired unconfirmed, the renewal's row sets nothing, Subscribe shows.
    func testARenewalAfterAnExpiredFirstPurchaseLeavesNothingUnconfirmed() async throws {
        let (bed, token) = try await registeredBed()
        bed.store.unfinishedResult = [bed.row(id: 1, token: token, expiresIn: 3_600)]
        bed.fake.crash()
        let center = await started(bed)
        XCTAssertEqual(center.unconfirmed, .notReached)

        bed.clock.advance(by: .seconds(3_601))
        bed.store.unfinishedResult.append(bed.row(id: 2, token: token, renewal: true))
        await center.foreground()?.value

        XCTAssertNil(center.unconfirmed)
    }

    // MARK: - Identity

    func testAFailedAccountIDChargesNothing() async throws {
        let bed = AccountBed()
        let center = await started(bed)
        bed.fake.crash()
        await center.buy()
        XCTAssertEqual(center.purchase, .accountFailed)
        XCTAssertEqual(bed.store.accountTokens, [])

        bed.fake.restart()
        bed.fake.failNext("register", with: .unsupportedVersion)
        await center.buy()
        XCTAssertEqual(center.purchase, .updateRequired, "an attestation or version refusal")
        XCTAssertEqual(bed.store.accountTokens, [])
    }

    func testARestoreWithNoIdentityCreatesItOnThePress() async throws {
        let bed = AccountBed()
        let center = await started(bed)
        XCTAssertFalse(bed.relay.isBuilt)
        bed.store.restoreResult = nil

        await center.restore()

        XCTAssertTrue(bed.relay.isBuilt)
        XCTAssertTrue(bed.ops.contains("register"))
        XCTAssertEqual(bed.store.restoreCalls, 1)
        XCTAssertEqual(center.purchase, .noSubscriptionFound)
    }

    func testARestoreWhoseAccountFailsAsksNothingOfApple() async throws {
        let bed = AccountBed()
        let center = await started(bed)
        bed.fake.crash()
        await center.restore()
        XCTAssertEqual(center.purchase, .accountFailed)
        XCTAssertEqual(bed.store.restoreCalls, 0)
    }

    func testTheCenterStartsWhenAnIdentityAppears() async throws {
        // After a link: the identity exists when `identityAppeared()` is called.
        let linked = AccountBed()
        let center = await started(linked)
        XCTAssertEqual(linked.store.updatesCalls, 0)
        XCTAssertEqual(linked.eventStreams, 0)
        let token = try await linked.register()
        linked.store.unfinishedResult = [linked.row(token: token)]

        center.identityAppeared()
        center.identityAppeared()
        await center.passTask?.value

        try await linked.until("the updates task") { linked.store.updatesCalls == 1 }
        XCTAssertEqual(linked.eventStreams, 1, "the events loop, once")
        XCTAssertEqual(linked.submitted.count, 1, "the sweep ran")
        XCTAssertEqual(center.phase, .paying(grace: false, macs: []))

        // After a buy, with no relaunch.
        let bought = AccountBed()
        let buyer = await started(bought)
        bought.store.purchaseResult = .pending
        await buyer.buy()
        await buyer.passTask?.value
        try await bought.until("the updates task") { bought.store.updatesCalls == 1 }
        XCTAssertEqual(bought.eventStreams, 1)
        XCTAssertEqual(buyer.purchase, .pending)
    }

    func testIdentityAppearedWithNoIdentityHoldsBack() async throws {
        let bed = AccountBed()
        let center = await started(bed)
        center.identityAppeared()
        XCTAssertEqual(bed.eventStreams, 0)
        XCTAssertFalse(bed.relay.isBuilt)
    }

    func testNoIdentityReadsNothingAndAttestsNothing() async throws {
        let bed = AccountBed()
        let center = await started(bed)
        await center.foreground()?.value
        await center.refresh()

        XCTAssertEqual(center.phase, .free(ended: false))
        XCTAssertEqual(bed.ops, [])
        XCTAssertFalse(bed.relay.isBuilt, "no session, so no signer")
        XCTAssertEqual(bed.store.totalCalls, 0, "no Transaction stream")
        XCTAssertEqual(bed.eventStreams, 0)

        bed.store.purchaseResult = .pending
        await center.buy()
        XCTAssertTrue(bed.relay.isBuilt, "the first Subscribe makes them")
        XCTAssertTrue(bed.ops.contains("register"))
    }

    // MARK: - Reads and events

    func testAReconnectReadsTheAccount() async throws {
        let (bed, token) = try await registeredBed()
        let center = await started(bed)
        let reads = bed.reads
        let row = bed.row(token: token)
        bed.store.unfinishedResult = [row]

        bed.emit(.reachable(false))
        bed.emit(.reachable(true))

        try await bed.until("the read") { bed.reads > reads }
        try await bed.until("the sweep") { bed.store.finished == [row] }
        try await bed.until("the answer") { center.phase == .paying(grace: false, macs: []) }
    }

    /// A push launch: the listeners are up, and no sweep or read until the app is active.
    func testAColdStartRunsNoPassUntilTheForeground() async throws {
        let (bed, token) = try await registeredBed()
        let row = bed.row(token: token)
        bed.store.unfinishedResult = [row]
        let opsBefore = bed.ops.count
        let center = bed.makeCenter()

        center.start()
        try await bed.until("the updates task") { bed.store.updatesCalls == 1 }
        XCTAssertEqual(bed.eventStreams, 1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(bed.store.unfinishedCalls, 0)
        XCTAssertEqual(bed.ops.count, opsBefore)
        XCTAssertEqual(center.phase, .checking)

        await center.foreground()?.value
        XCTAssertEqual(bed.store.finished, [row])
        XCTAssertEqual(center.phase, .paying(grace: false, macs: []))
    }

    func testAFailedPassDoesNotBlockTheForeground() async throws {
        let (bed, _) = try await registeredBed()
        bed.fake.crash()
        let center = await started(bed)
        XCTAssertEqual(center.phase, .unknown)

        bed.fake.restart()
        await center.foreground()?.value

        XCTAssertEqual(center.phase, .free(ended: false), "no minute's wait after a pass that reached nothing")
    }

    func testAForegroundRunsAtMostOnceAMinute() async throws {
        let (bed, _) = try await registeredBed()
        let center = await started(bed)
        let reads = bed.reads
        XCTAssertNil(center.foreground())
        bed.clock.advance(by: .seconds(30))
        XCTAssertNil(center.foreground())
        bed.clock.advance(by: .seconds(31))
        await center.foreground()?.value
        XCTAssertEqual(bed.reads, reads + 1)
    }

    func testPendingAndCancelledSubmitNothing() async throws {
        let (bed, _) = try await registeredBed()
        let product = RelayProduct(id: "relay", displayPrice: "$4.99")
        bed.store.productResult = product
        let center = await started(bed)
        await center.loadProduct()

        bed.store.purchaseResult = .cancelled
        await center.buy()
        XCTAssertEqual(center.purchase, .ready(product))

        bed.store.purchaseResult = .pending
        await center.buy()
        XCTAssertEqual(center.purchase, .pending)

        XCTAssertEqual(bed.submitted, [])
        XCTAssertEqual(bed.store.finished, [])
        XCTAssertNil(center.unconfirmed, "no transaction, nothing unconfirmed")
    }

    func testAnUnverifiedPurchaseSubmitsNothing() async throws {
        let (bed, _) = try await registeredBed()
        bed.store.purchaseResult = .unverified
        let center = await started(bed)
        await center.buy()
        XCTAssertEqual(center.purchase, .refused)
        XCTAssertEqual(bed.submitted, [])
    }

    func testOneTransactionIsSubmittedOnce() async throws {
        let (bed, token) = try await registeredBed()
        let center = await started(bed)
        try await bed.until("the updates task") { bed.store.updatesCalls == 1 }
        let row = bed.row(token: token)
        bed.sell(row)
        bed.http.hold(row.jws)
        let press = Task { await center.buy() }
        try await bed.until("the submit") { bed.http.isHolding(row.jws) }

        bed.store.emit(row)
        try await Task.sleep(for: .milliseconds(30))
        bed.http.release(row.jws)
        await press.value

        // And a delivery after the answer: the row is settled.
        bed.store.emit(row)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(bed.submitted, [row.jws])
        XCTAssertEqual(bed.store.finished, [row], "finish runs once")
    }

    func testARenewalIsSubmitted() async throws {
        let (bed, token) = try await registeredBed()
        let center = await started(bed)
        try await bed.until("the updates task") { bed.store.updatesCalls == 1 }
        let renewal = bed.row(token: token, renewal: true)
        bed.store.emit(renewal)
        try await bed.until("finished") { bed.store.finished == [renewal] }
        XCTAssertEqual(bed.submitted, [renewal.jws])
        try await bed.until("read") { center.phase == .paying(grace: false, macs: []) }
    }

    func testARefusedRenewalChangesNoPurchaseState() async throws {
        let (bed, token) = try await registeredBed()
        let center = await started(bed)
        try await bed.until("the updates task") { bed.store.updatesCalls == 1 }
        bed.fake.failNext("submitTransaction", with: .invalidTransaction)
        bed.store.emit(bed.row(token: token, renewal: true))
        try await bed.until("the answer") { center.unconfirmed != nil }
        XCTAssertEqual(center.purchase, .idle)
        XCTAssertEqual(center.unconfirmed, .refused)
    }

    func testARenewalWithNoRelayIsNotUnconfirmed() async throws {
        let (bed, token) = try await registeredBed()
        let renewal = bed.row(token: token, renewal: true)
        bed.store.unfinishedResult = [renewal]
        bed.http.hold(renewal.jws)
        let center = bed.makeCenter()
        center.start()
        center.foreground()
        try await bed.until("the submit") { bed.http.isHolding(renewal.jws) }
        XCTAssertNil(center.unconfirmed, "no .confirming")
        bed.fake.crash()
        bed.http.release(renewal.jws)
        await center.passTask?.value
        XCTAssertNil(center.unconfirmed, "no .notReached")

        bed.fake.restart()
        bed.fake.failNext("submitTransaction", with: .invalidTransaction)
        await foreground(center, bed)
        XCTAssertEqual(center.unconfirmed, .refused, "a definite refusal does set it")
    }

    // MARK: - Settling and closing

    /// Puts `center`'s press in `state` through the real flow; `row` is the press's transaction.
    private func reach(_ state: Purchase, _ center: RelayAccountCenter, _ bed: AccountBed, token: UUID) async {
        bed.sell(bed.row(id: 1, token: token))
        switch state {
        case .pending:
            bed.store.purchaseResult = .pending
            bed.store.unfinishedResult = []
            await center.buy()
        case .boughtNotConfirmed:
            bed.fake.crash()
            await center.buy()
            bed.fake.restart()
        case .refused:
            Refusal.invalid.arm(on: bed)
            await center.buy()
        case .transferLimit:
            Refusal.transferLimit.arm(on: bed)
            await center.buy()
        case .notImplemented:
            Refusal.notImplemented.arm(on: bed)
            await center.buy()
            Refusal.notImplemented.disarm(on: bed)
        case .updateRequired:
            Refusal.attestationUpdate.arm(on: bed)
            await center.buy()
        case .noSubscriptionFound:
            bed.store.unfinishedResult = []
            bed.store.restoreResult = nil
            await center.restore()
        case .storeFailed:
            bed.store.unfinishedResult = []
            bed.store.purchaseError = RelayStoreError.productUnavailable
            await center.buy()
            bed.store.purchaseError = nil
        default:
            XCTFail("not a finished press: \(state)")
        }
        XCTAssertEqual(center.purchase, state)
    }

    private static let finishedPresses: [Purchase] = [
        .pending, .boughtNotConfirmed, .refused, .transferLimit, .notImplemented, .updateRequired, .noSubscriptionFound, .storeFailed
    ]

    func testAnEntitlementAnswerSettlesAFinishedPress() async throws {
        for state in Self.finishedPresses {
            for path in ["updates", "sweep", "reconnect"] {
                let (bed, token) = try await registeredBed()
                let center = await started(bed)
                try await bed.until("the updates task") { bed.store.updatesCalls == 1 }
                await reach(state, center, bed, token: token)
                bed.clock.advance(by: .seconds(1))
                let approved = bed.row(id: 7, original: "7000", token: token)
                switch path {
                case "updates":
                    bed.store.emit(approved)
                case "sweep":
                    bed.store.unfinishedResult.append(approved)
                    await foreground(center, bed)
                default:
                    try await paying(bed, token)
                    bed.emit(.reachable(true))
                }
                try await bed.until("\(state) by \(path)") { center.purchase == .done }
            }
        }
    }

    func testARunningPressIsNotSettled() async throws {
        for state in ["buying", "confirming", "restoring"] {
            let (bed, token) = try await registeredBed()
            let center = await started(bed)
            let row = bed.row(id: 1, token: token)
            let press: Task<Void, Never>
            switch state {
            case "buying":
                bed.store.purchaseResult = .pending
                bed.store.parkPurchase()
                press = Task { await center.buy() }
                try await bed.until("the sheet") { bed.store.purchaseIsParked }
            case "confirming":
                bed.sell(row)
                bed.http.hold(row.jws)
                press = Task { await center.buy() }
                try await bed.until("the submit") { bed.http.isHolding(row.jws) }
            default:
                bed.store.restoreResult = row
                bed.http.hold(row.jws)
                press = Task { await center.restore() }
                try await bed.until("the submit") { bed.http.isHolding(row.jws) }
            }
            let before = center.purchase
            try await paying(bed, token)
            await center.refresh()
            XCTAssertEqual(center.purchase, before, state)

            bed.store.releasePurchase()
            bed.http.release(row.jws)
            await press.value
        }
    }

    func testScreenClosedClearsAFinishedPress() async throws {
        let cleared: [Purchase] = [
            .boughtNotConfirmed, .refused, .transferLimit, .notImplemented, .updateRequired, .noSubscriptionFound, .storeFailed
        ]
        for state in cleared {
            let (bed, token) = try await registeredBed()
            let center = await started(bed)
            await reach(state, center, bed, token: token)
            center.screenClosed()
            XCTAssertEqual(center.purchase, .idle, "\(state)")
        }

        // .done
        let (bed, token) = try await registeredBed()
        let center = await started(bed)
        bed.sell(bed.row(token: token))
        await center.buy()
        XCTAssertEqual(center.purchase, .done)
        center.screenClosed()
        XCTAssertEqual(center.purchase, .idle)

        // .accountFailed
        let noIdentity = AccountBed()
        let failed = await started(noIdentity)
        noIdentity.fake.crash()
        await failed.buy()
        XCTAssertEqual(failed.purchase, .accountFailed)
        failed.screenClosed()
        XCTAssertEqual(failed.purchase, .idle)

        // .productFailed
        let (emptyBed, _) = try await registeredBed()
        let empty = await started(emptyBed)
        await empty.loadProduct()
        XCTAssertEqual(empty.purchase, .productFailed)
        empty.screenClosed()
        XCTAssertEqual(empty.purchase, .idle)
    }

    func testScreenClosedLeavesARunningPressAndPending() async throws {
        let (bed, token) = try await registeredBed()
        let center = await started(bed)
        await reach(.pending, center, bed, token: token)
        center.screenClosed()
        XCTAssertEqual(center.purchase, .pending)

        bed.store.parkPurchase()
        let press = Task { await center.buy() }
        try await bed.until("the sheet") { bed.store.purchaseIsParked }
        center.screenClosed()
        XCTAssertEqual(center.purchase, .buying)
        bed.store.releasePurchase()
        await press.value
    }

    func testARestoreEndingBeforeTheScreenOpensKeepsItsResult() async throws {
        let (bed, token) = try await registeredBed()
        bed.store.productResult = RelayProduct(id: "relay", displayPrice: "$4.99")
        let center = await started(bed)

        bed.store.restoreResult = nil
        await center.restore()
        await center.loadProduct()
        XCTAssertEqual(center.purchase, .noSubscriptionFound)
        center.screenClosed()
        XCTAssertEqual(center.purchase, .idle)

        bed.store.restoreResult = bed.row(token: token)
        bed.fake.failNext("submitTransaction", with: .invalidTransaction)
        await center.restore()
        await center.loadProduct()
        XCTAssertEqual(center.purchase, .refused)
        XCTAssertEqual(bed.store.productCalls, 0, "loadProduct leaves it")
        center.screenClosed()
        XCTAssertEqual(center.purchase, .idle)
    }

    func testARestoreSubmitsAFreshTransactionNeverACachedOne() async throws {
        let (bed, token) = try await registeredBed()
        let center = await started(bed)
        let first = bed.row(id: 1, token: token)
        bed.store.restoreResult = first
        bed.fake.failNext("submitTransaction", with: .invalidTransaction)
        await center.restore()

        bed.clock.advance(by: .seconds(1))
        let second = bed.row(id: 1, token: token)
        bed.store.restoreResult = second
        await center.restore()

        XCTAssertEqual(bed.store.restoreCalls, 2)
        XCTAssertEqual(bed.submitted, [first.jws, second.jws])
    }

    func testARestoreRunsAndWithNothingSaysSo() async throws {
        let (bed, token) = try await registeredBed()
        let center = await started(bed)
        bed.store.restoreResult = bed.row(token: token)
        await center.restore()
        XCTAssertEqual(center.purchase, .done)
        XCTAssertEqual(center.phase, .paying(grace: false, macs: []))

        center.screenClosed()
        bed.store.restoreResult = nil
        await center.restore()
        XCTAssertEqual(center.purchase, .noSubscriptionFound)
    }

    func testAFailedStoreCallIsStoreFailedAndSubmitsNothing() async throws {
        let (bed, _) = try await registeredBed()
        let center = await started(bed)
        bed.store.purchaseError = RelayStoreError.productUnavailable
        await center.buy()
        XCTAssertEqual(center.purchase, .storeFailed)
        XCTAssertEqual(bed.submitted, [])

        center.screenClosed()
        bed.store.restoreError = RelayStoreError.productUnavailable
        await center.restore()
        XCTAssertEqual(center.purchase, .storeFailed)
        XCTAssertNil(center.unconfirmed)
        XCTAssertEqual(bed.submitted, [])
    }

    func testAStoreFailureStaysThroughLoadProductAndClearsOnClose() async throws {
        let (bed, _) = try await registeredBed()
        bed.store.productResult = RelayProduct(id: "relay", displayPrice: "$4.99")
        let center = await started(bed)
        bed.store.restoreError = RelayStoreError.productUnavailable
        await center.restore()

        await center.loadProduct()
        XCTAssertEqual(center.purchase, .storeFailed, "a Restore's result stays until it has been on screen")
        XCTAssertEqual(bed.store.productCalls, 0)

        center.screenClosed()
        XCTAssertEqual(center.purchase, .idle)
    }

    func testACancelledRestoreReturnsToThePriorStateWithNoMessage() async throws {
        let product = RelayProduct(id: "relay", displayPrice: "$4.99")
        let (bed, _) = try await registeredBed()
        bed.store.productResult = product
        let center = await started(bed)
        bed.store.restoreError = RelayStoreError.cancelled

        await center.restore()
        XCTAssertEqual(center.purchase, .idle)

        await center.loadProduct()
        await center.restore()
        XCTAssertEqual(center.purchase, .ready(product))

        bed.store.restoreError = nil
        bed.store.restoreResult = nil
        await center.restore()
        XCTAssertEqual(center.purchase, .noSubscriptionFound)
        bed.store.restoreError = RelayStoreError.cancelled
        await center.restore()
        XCTAssertEqual(center.purchase, .noSubscriptionFound)
    }

    /// A center whose account fails while the gate says so, as a phone with no way to reach the relay.
    private func gatedCenter(_ bed: AccountBed) -> (RelayAccountCenter, AccountGate) {
        let live = RelayAccountLink.live(bed.relay)
        let gate = AccountGate()
        let link = RelayAccountLink(
            hasIdentity: live.hasIdentity,
            account: {
                if gate.fails { throw HostedRelayPairing.Refusal.unreachable }
                return try live.account()
            },
            events: { nil }
        )
        return (RelayAccountCenter(link: link, store: bed.store, defaults: bed.defaults) { [] }, gate)
    }

    /// **Try Again** on S46 repeats the press that stopped at the account: a failed Restore never becomes a purchase.
    func testTryAgainAfterAFailedAccountRepeatsThePress() async throws {
        let bed = AccountBed()
        let (center, gate) = gatedCenter(bed)

        await center.restore()
        XCTAssertEqual(center.purchase, .accountFailed)
        gate.fails = false
        bed.store.restoreResult = nil
        await center.retryAccount()
        XCTAssertEqual(bed.store.restoreCalls, 1)
        XCTAssertTrue(bed.store.accountTokens.isEmpty, "no purchase was asked of Apple")
        XCTAssertEqual(center.purchase, .noSubscriptionFound)

        center.screenClosed()
        gate.fails = true
        await center.buy()
        XCTAssertEqual(center.purchase, .accountFailed)
        gate.fails = false
        bed.store.purchaseResult = .pending
        await center.retryAccount()
        XCTAssertEqual(bed.store.accountTokens.count, 1)
        XCTAssertEqual(bed.store.restoreCalls, 1, "no restore was asked of Apple")
        XCTAssertEqual(center.purchase, .pending)

        // Off S46 it presses nothing.
        await center.retryAccount()
        XCTAssertEqual(bed.store.accountTokens.count, 1)
    }

    /// The account answered this time, so S46's "Couldn't reach Relay" must not come back on a cancel.
    func testACancelledRestoreFromTheAccountFrameDoesNotReturnToIt() async throws {
        // No price known: `.idle`, and the open screen loads.
        let bed = AccountBed()
        let (center, gate) = gatedCenter(bed)
        await center.restore()
        XCTAssertEqual(center.purchase, .accountFailed)
        gate.fails = false
        bed.store.restoreError = RelayStoreError.cancelled
        await center.retryAccount()
        XCTAssertEqual(center.purchase, .idle)

        // A price known: back to it.
        let priced = AccountBed()
        let product = RelayProduct(id: "relay", displayPrice: "$4.99")
        priced.store.productResult = product
        let (known, knownGate) = gatedCenter(priced)
        await known.loadProduct()
        await known.restore()
        XCTAssertEqual(known.purchase, .accountFailed)
        knownGate.fails = false
        priced.store.restoreError = RelayStoreError.cancelled
        await known.retryAccount()
        XCTAssertEqual(known.purchase, .ready(product))
    }

    /// **Load the Price** on S45 and S57 with no price: the result goes, the load runs, and a failure there is S22.
    func testReloadProductLeavesAResultWithNoPrice() async throws {
        let (bed, _) = try await registeredBed()
        let center = await started(bed)
        let product = RelayProduct(id: "relay", displayPrice: "$4.99")

        await center.restore()
        XCTAssertEqual(center.purchase, .noSubscriptionFound)
        await center.reloadProduct()
        XCTAssertEqual(center.purchase, .productFailed, "S22 from the store's empty answer")
        XCTAssertEqual(bed.store.productCalls, 1)

        center.screenClosed()
        bed.store.restoreError = RelayStoreError.productUnavailable
        await center.restore()
        XCTAssertEqual(center.purchase, .storeFailed)
        bed.store.productResult = product
        await center.reloadProduct()
        XCTAssertEqual(center.purchase, .ready(product))

        // S22's own Retry.
        center.screenClosed()
        bed.store.productResult = nil
        await center.loadProduct()
        XCTAssertEqual(center.purchase, .productFailed)
        bed.store.productResult = product
        await center.reloadProduct()
        XCTAssertEqual(center.purchase, .ready(product))
    }

    /// A cancel must not land on S21 with no load running. `.idle` is the contract: the open screen loads on it.
    func testACancelledRestoreLeavesNoStateNothingAdvances() async throws {
        let product = RelayProduct(id: "relay", displayPrice: "$4.99")

        // Prior .loadingProduct, the price already known.
        let (known, _) = try await registeredBed()
        known.store.productResult = product
        known.store.restoreError = RelayStoreError.cancelled
        let knownCenter = await started(known)
        await knownCenter.loadProduct()
        known.store.parkProduct()
        let reload = Task { await knownCenter.loadProduct() }
        try await known.until("the load") { known.store.productIsParked }
        XCTAssertEqual(knownCenter.purchase, .loadingProduct)
        await knownCenter.restore()
        XCTAssertEqual(knownCenter.purchase, .ready(product))
        known.store.releaseProduct()
        await reload.value
        XCTAssertEqual(knownCenter.purchase, .ready(product))

        // Prior .loadingProduct, no price yet.
        let (fresh, _) = try await registeredBed()
        fresh.store.productResult = product
        fresh.store.restoreError = RelayStoreError.cancelled
        let freshCenter = await started(fresh)
        fresh.store.parkProduct()
        let load = Task { await freshCenter.loadProduct() }
        try await fresh.until("the load") { fresh.store.productIsParked }
        await freshCenter.restore()
        XCTAssertEqual(freshCenter.purchase, .idle)
        fresh.store.releaseProduct()
        await load.value
        XCTAssertEqual(freshCenter.purchase, .idle, "the old load writes nothing over a press's end")

        // Prior .loadingProduct, the load ending during the restore: S21 would stay with none running.
        let (during, _) = try await registeredBed()
        during.store.productResult = product
        during.store.restoreError = RelayStoreError.cancelled
        let duringCenter = await started(during)
        during.store.parkProduct()
        during.store.parkRestore()
        let duringLoad = Task { await duringCenter.loadProduct() }
        try await during.until("the load") { during.store.productIsParked }
        let press = Task { await duringCenter.restore() }
        try await during.until("the sign-in") { during.store.restoreIsParked }
        during.store.releaseProduct()
        await duringLoad.value
        XCTAssertEqual(duringCenter.purchase, .restoring, "a load does not write during a press")
        during.store.releaseRestore()
        await press.value
        XCTAssertEqual(duringCenter.purchase, .ready(product))

        // Prior .idle: stays, and the screen's load gets the price.
        let (idle, _) = try await registeredBed()
        idle.store.productResult = product
        idle.store.restoreError = RelayStoreError.cancelled
        let idleCenter = await started(idle)
        await idleCenter.restore()
        XCTAssertEqual(idleCenter.purchase, .idle)
        await idleCenter.loadProduct()
        XCTAssertEqual(idleCenter.purchase, .ready(product))
    }

    /// A throw says nothing about a charge: what arrives after it decides.
    func testAStoreFailureThenADeliverySettlesOrShowsTheRefusal() async throws {
        for refused in [false, true] {
            let (bed, token) = try await registeredBed()
            let center = await started(bed)
            try await bed.until("the updates task") { bed.store.updatesCalls == 1 }
            bed.store.purchaseError = RelayStoreError.productUnavailable
            await center.buy()
            XCTAssertEqual(center.purchase, .storeFailed)

            if refused { bed.fake.failNext("submitTransaction", with: .invalidTransaction) }
            bed.store.emit(bed.row(token: token))

            if refused {
                try await bed.until("the refusal") { center.unconfirmed == .refused }
                XCTAssertEqual(center.purchase, .storeFailed)
                XCTAssertEqual(bed.store.finished, [])
            } else {
                try await bed.until("settled") { center.purchase == .done }
                XCTAssertEqual(bed.store.finished.count, 1)
            }
        }
    }

    // MARK: - Lapse and move

    private func targets(on bed: AccountBed) -> (relay: FakeLapseTarget, other: FakeLapseTarget, cloud: FakeLapseTarget) {
        let relay = FakeLapseTarget(isOnRelay: true)
        let other = FakeLapseTarget(isOnRelay: true)
        let cloud = FakeLapseTarget(isOnRelay: false)
        bed.targets = [relay, other, cloud]
        return (relay, other, cloud)
    }

    func testAMoveControlLapsesEveryRelayMac() async throws {
        let (bed, token) = try await registeredBed()
        try await paying(bed, token)
        let macs = targets(on: bed)
        let center = await started(bed)
        XCTAssertEqual(macs.relay.lapses, 0)

        bed.emit(.control(kind: .subscriptionMoved, detail: ""))

        try await bed.until("the lapse") { macs.relay.lapses == 1 && macs.other.lapses == 1 }
        XCTAssertEqual(center.phase, .moved, "applied at once")
        XCTAssertEqual(center.switchReason, TransportFollowerPolicy.lapseReason)
        XCTAssertEqual(macs.cloud.lapses, 0)
    }

    func testAMoveLearnedFromAccountStateLapsesEveryRelayMac() async throws {
        let (bed, token) = try await registeredBed()
        try await paying(bed, token)
        let newPhone = try await bed.otherPhone(seed: 0x42)
        let macs = targets(on: bed)
        let phone = try XCTUnwrap(try bed.relay.session()).client.deviceID
        try bed.fake.moveSubscription(fromPhone: phone, toPhone: newPhone.deviceID)

        // The phone was offline when the control went out: the next launch's read tells it.
        let center = await started(bed)

        XCTAssertEqual(center.phase, .moved)
        XCTAssertEqual(macs.relay.lapses, 1)
        XCTAssertEqual(macs.other.lapses, 1)
        XCTAssertEqual(macs.cloud.lapses, 0)
    }

    func testAnExpiryControlLapsesEveryRelayMac() async throws {
        for event in [HostedRelayEvent.control(kind: .entitlementExpired, detail: ""), .entitlementInactive] {
            let (bed, token) = try await registeredBed()
            try await paying(bed, token)
            let macs = targets(on: bed)
            let center = await started(bed)
            XCTAssertEqual(center.phase, .paying(grace: false, macs: []))
            try await bed.fake.setEntitlement(accountID: token.uuidString.lowercased(), state: "expired", for: .zero)

            bed.emit(event)

            try await bed.until("the lapse") { macs.relay.lapses == 1 && macs.other.lapses == 1 }
            XCTAssertEqual(center.phase, .free(ended: true))
            XCTAssertEqual(macs.cloud.lapses, 0)
        }
    }

    /// A control is definite: with the read failing too, the phase is unknown and the relay Macs still lapse.
    func testAnExpiryControlLapsesEvenWhenItsReadFails() async throws {
        let (bed, token) = try await registeredBed()
        try await paying(bed, token)
        let macs = targets(on: bed)
        let center = await started(bed)
        bed.fake.crash()

        bed.emit(.control(kind: .entitlementExpired, detail: ""))

        try await bed.until("the lapse") { macs.relay.lapses == 1 }
        XCTAssertEqual(center.phase, .unknown)
    }

    /// The read after a late control says paying: the relay's last answer wins and no Mac is sent back.
    func testAnExpiryControlCorrectedByAPayingReadLapsesNothing() async throws {
        let (bed, token) = try await registeredBed()
        try await paying(bed, token)
        let macs = targets(on: bed)
        let center = await started(bed)
        let reads = bed.reads

        bed.emit(.control(kind: .entitlementExpired, detail: ""))

        try await bed.until("the read") { bed.reads > reads }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(macs.relay.lapses, 0)
        XCTAssertEqual(center.phase, .paying(grace: false, macs: []))
    }

    /// Apple renewed and the row is not sent yet: the sweep runs first, so the billing boundary sends no Mac back.
    func testAnUnsentRenewalAtExpiryLapsesNothing() async throws {
        for event in [HostedRelayEvent.control(kind: .entitlementExpired, detail: ""), .entitlementInactive] {
            let (bed, token) = try await registeredBed()
            try await paying(bed, token)
            let macs = targets(on: bed)
            let center = await started(bed)
            try await bed.fake.setEntitlement(accountID: token.uuidString.lowercased(), state: "expired", for: .zero)
            let renewal = bed.row(token: token, renewal: true)
            bed.store.unfinishedResult = [renewal]

            bed.emit(event)

            try await bed.until("the renewal confirmed") { bed.store.finished == [renewal] }
            try await bed.until("the read") { center.phase == .paying(grace: false, macs: []) }
            XCTAssertEqual(macs.relay.lapses, 0, "\(event)")
            XCTAssertEqual(bed.submitted, [renewal.jws], "\(event)")
        }
    }

    /// The bound still applies: a refused renewal is not sent again, and the expiry stands.
    func testARefusedRenewalAtExpiryStillLapses() async throws {
        let (bed, token) = try await registeredBed()
        let renewal = bed.row(token: token, renewal: true)
        bed.store.unfinishedResult = [renewal]
        bed.fake.failNext("submitTransaction", with: .invalidTransaction)
        let center = await started(bed)
        XCTAssertEqual(bed.submitted.count, 1)
        let macs = targets(on: bed)
        try await bed.fake.setEntitlement(accountID: token.uuidString.lowercased(), state: "expired", for: .zero)

        bed.emit(.control(kind: .entitlementExpired, detail: ""))

        try await bed.until("the lapse") { macs.relay.lapses == 1 }
        XCTAssertEqual(bed.submitted.count, 1)
        XCTAssertEqual(center.phase, .free(ended: true))
    }

    func testAnOlderReadDoesNotOverwriteAMove() async throws {
        let (bed, token) = try await registeredBed()
        try await paying(bed, token)
        let center = await started(bed)
        bed.http.holdReads()
        let read = Task { await center.refresh() }
        try await bed.until("the read in flight") { bed.http.isHoldingRead }

        bed.emit(.control(kind: .subscriptionMoved, detail: ""))
        try await bed.until("the move") { center.phase == .moved }
        bed.http.releaseReads()
        await read.value

        XCTAssertEqual(center.phase, .moved, "the older read still said paying")
    }

    func testADoneDoesNotWaitForTheLapseEnd() async throws {
        let (bed, token) = try await registeredBed()
        let macs = targets(on: bed)
        macs.relay.parksEnd = true
        let center = await started(bed)
        bed.sell(bed.row(token: token))

        // A press ends though one hub's iCloud call is still out, and the other hub is not held behind it.
        await center.buy()

        XCTAssertEqual(center.purchase, .done)
        try await bed.until("the parked hub") { macs.relay.endParked }
        try await bed.until("the other hub") { macs.other.ended == 1 }
        XCTAssertEqual(macs.relay.ended, 0)

        macs.relay.releaseEnd()
        await center.lapseEndsFinished()
        XCTAssertEqual(macs.relay.ended, 1)
    }

    func testAnICloudMacIsNotAsked() async throws {
        let (bed, _) = try await registeredBed()
        let cloud = FakeLapseTarget(isOnRelay: false)
        bed.targets = [cloud]
        let center = await started(bed)
        XCTAssertEqual(center.phase, .free(ended: false))
        XCTAssertEqual(cloud.lapses, 0)
    }

    func testANotPayingReadLapsesARelayMac() async throws {
        let (bed, token) = try await registeredBed()
        try await bed.fake.setEntitlement(accountID: token.uuidString.lowercased(), state: "revoked", for: .zero)
        let relay = FakeLapseTarget(isOnRelay: true)
        bed.targets = [relay]
        let center = await started(bed)
        XCTAssertEqual(center.phase, .free(ended: true))
        XCTAssertEqual(relay.lapses, 1)
    }

    func testAFailedReadIsUnknownAndLapsesNothing() async throws {
        let (bed, token) = try await registeredBed()
        try await paying(bed, token)
        let macs = targets(on: bed)
        let center = await started(bed)
        bed.fake.crash()

        await center.refresh()

        XCTAssertEqual(center.phase, .unknown)
        XCTAssertNil(center.switchReason)
        XCTAssertEqual(macs.relay.lapses, 0)
    }

    func testAGraceAccountIsPayingAndLapsesNothing() async throws {
        let (bed, token) = try await registeredBed()
        try await paying(bed, token, state: "grace")
        let macs = targets(on: bed)
        let center = await started(bed)
        XCTAssertEqual(center.phase, .paying(grace: true, macs: []))
        XCTAssertNil(center.switchReason)
        XCTAssertEqual(macs.relay.lapses, 0)
    }

    func testPayingAgainMovesNoMac() async throws {
        let (bed, token) = try await registeredBed()
        try await bed.fake.setEntitlement(accountID: token.uuidString.lowercased(), state: "expired", for: .zero)
        let macs = targets(on: bed)
        let center = await started(bed)
        XCTAssertEqual(macs.relay.lapses, 1)
        XCTAssertEqual(center.switchReason, TransportFollowerPolicy.lapseReason)

        try await paying(bed, token)
        await center.refresh()

        XCTAssertEqual(center.phase, .paying(grace: false, macs: []))
        XCTAssertEqual(macs.relay.lapses, 1, "nothing more asked of the Macs")
        XCTAssertNil(center.switchReason)
    }

    func testAPayingAnswerEndsTheLapseOnce() async throws {
        let (bed, token) = try await registeredBed()
        try await bed.fake.setEntitlement(accountID: token.uuidString.lowercased(), state: "expired", for: .zero)
        let macs = targets(on: bed)
        let center = await started(bed)
        XCTAssertEqual(macs.relay.ended, 0, "not paying yet")

        try await paying(bed, token, state: "grace")
        await center.refresh()
        await center.lapseEndsFinished()
        XCTAssertEqual(macs.relay.ended, 1)
        XCTAssertEqual(macs.other.ended, 1)

        await center.refresh()
        await center.lapseEndsFinished()
        XCTAssertEqual(macs.relay.ended, 1, "only when the entitlement returns")
    }

    /// A relaunch forgets the phase, not the kept lapse record: the first paying read ends it.
    func testAPayingReadAtLaunchEndsAKeptLapse() async throws {
        let (bed, token) = try await registeredBed()
        try await paying(bed, token)
        let relay = FakeLapseTarget(isOnRelay: true)
        bed.targets = [relay]
        let center = await started(bed)
        await center.lapseEndsFinished()
        XCTAssertEqual(relay.ended, 1)
    }

    func testAPayingReadKeepsWasPayingUntilCleared() async throws {
        let (bed, token) = try await registeredBed()
        let center = await started(bed)
        XCTAssertFalse(center.wasPaying)

        try await paying(bed, token)
        await center.refresh()
        XCTAssertTrue(center.wasPaying)
        XCTAssertTrue(bed.makeCenter().wasPaying, "persisted")

        center.clearWasPaying()
        XCTAssertFalse(center.wasPaying)
        XCTAssertFalse(bed.makeCenter().wasPaying)

        await center.refresh()
        XCTAssertTrue(center.wasPaying, "a new paying read sets it again")
    }

    func testASlotRemovedControlReads() async throws {
        let (bed, _) = try await registeredBed()
        let center = await started(bed)
        let reads = bed.reads
        bed.emit(.control(kind: .slotRemoved, detail: "mac"))
        try await bed.until("the read") { bed.reads > reads }
        XCTAssertEqual(center.phase, .free(ended: false))
    }

    func testUpdateRequiredLatchesAndClears() async throws {
        for event in [HostedRelayEvent.unsupportedVersion, .attestation(.updateRequired)] {
            let (bed, _) = try await registeredBed()
            let center = await started(bed)
            XCTAssertFalse(center.updateRequired)
            bed.emit(event)
            try await bed.until("latched") { center.updateRequired }
            await center.refresh()
            XCTAssertTrue(center.updateRequired, "a read does not clear it")
            bed.emit(.reachable(true))
            try await bed.until("cleared") { !center.updateRequired }
        }
    }

    func testAttestationOutcomes() async throws {
        let (bed, token) = try await registeredBed()
        try await paying(bed, token)
        let center = await started(bed)
        let phase = center.phase
        XCTAssertEqual(phase, .paying(grace: false, macs: []))

        // Events run in order: once the second is seen, `.retryLater` was handled.
        bed.emit(.attestation(.retryLater(after: .seconds(60))))
        bed.emit(.unsupportedVersion)
        try await bed.until("handled") { center.updateRequired }
        XCTAssertEqual(center.phase, phase, ".retryLater: the phase stays")

        bed.emit(.attestation(.notSupported))
        try await bed.until("unknown") { center.phase == .unknown }
    }

    // MARK: - Wiring

    func testAnEmptyOriginTouchesNoStoreKit() async throws {
        let bed = try await Bed.make(self, on: .cloudKit, relayOff: true)
        let store = FakeSubscriptionStore()
        var asked = 0
        bed.root.wireRelayAccount {
            asked += 1
            return store
        }
        await bed.root.becameActive().value

        XCTAssertNil(bed.root.env.relayAccount)
        XCTAssertEqual(asked, 0, "the store is not even built")
        XCTAssertEqual(store.totalCalls, 0)
    }

    /// On a cold launch the center's first pass waits for the foreground (a push launch stays frugal).
    func testARelayRootBuildsItsCenterAndForwardsTheForeground() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let store = FakeSubscriptionStore()
        bed.root.wireRelayAccount { store }
        let center = try XCTUnwrap(bed.root.env.relayAccount)
        XCTAssertEqual(store.unfinishedCalls, 0, "no pass before the app is active")
        XCTAssertEqual(center.phase, .checking)

        await bed.root.becameActive().value
        await center.passTask?.value

        XCTAssertEqual(store.unfinishedCalls, 1)
        XCTAssertEqual(center.phase, .paying(grace: false, macs: [bed.mac.deviceID]))
    }

    /// The real session: a read that says expired asks the hub for iCloud with the lapse's reason, and paying again
    /// clears the request.
    func testALapseReachesTheRealSessionAndPayingAgainEndsIt() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let store = FakeSubscriptionStore()
        bed.root.wireRelayAccount { store }
        let center = try XCTUnwrap(bed.root.env.relayAccount)
        await center.foreground()?.value
        let account = try await bed.fake.accountID(ofPhone: bed.phone.deviceID)
        let session = try await bed.orderedSession()
        try await bed.fake.setEntitlement(accountID: account, state: "expired", for: .zero)

        // The socket's own reconnect pass may read beside this one: the newest read answers, so wait for its effect.
        XCTAssertTrue(session.isOnRelay)
        await center.refresh()
        let poller = AccountBed()
        try await poller.until("the lapse's request") { session.transportRequest?.reason == TransportFollowerPolicy.lapseReason }
        XCTAssertEqual(center.phase, .free(ended: true))

        try await bed.fake.setEntitlement(accountID: account, state: "active", for: .seconds(86_400))
        await center.refresh()
        try await poller.until("the request withdrawn") { session.transportRequest == nil }
    }

    /// The relay link's and the upgrade's points start a center that held back with no identity.
    func testAFinishedLinkAndAnUpgradeStartTheCenter() async throws {
        for point in ["link", "upgrade"] {
            let bed = try await Bed.make(self, on: .relay)
            let store = FakeSubscriptionStore()
            var hasIdentity = false
            let live = RelayAccountLink.live(bed.root.env.relay)
            let link = RelayAccountLink(hasIdentity: { hasIdentity }, account: live.account, events: live.events)
            let center = RelayAccountCenter(link: link, store: store, defaults: AccountBed().defaults) { [] }
            bed.root.env.relayAccount = center
            center.start()
            XCTAssertEqual(store.totalCalls, 0, point)

            hasIdentity = true
            if point == "link" {
                _ = try await bed.root.prepare(route: .hostedRelay(macDeviceID: bed.mac.deviceID), hubID: bed.hubID, fresh: false)
            } else {
                _ = await bed.root.rewriteDeviceRecord(hubID: bed.hubID)
            }
            await center.passTask?.value
            XCTAssertGreaterThanOrEqual(store.unfinishedCalls, 1, point)
        }
    }

    func testAnICloudSessionIsNotOnRelay() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        XCTAssertFalse(try XCTUnwrap(bed.root.env.session(bed.hubID)).isOnRelay)
    }
}

/// A value a `@Sendable` closure writes and the test reads.
private final class Captured<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value { lock.withLock { stored } }

    func set(_ value: Value) {
        lock.withLock { stored = value }
    }
}

private final class AccountGate: @unchecked Sendable {
    var fails = true
}

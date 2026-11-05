import Foundation
import WatchtowerHostedRelay
import WatchtowerRelayProto
import XCTest
@testable import WatchtowerMobile

/// Who may send by itself (relay client Phase 4, final review): only a press moves the subscription. The relay moves it on
/// any fresh submit from the transaction's token's account or the original one, and StoreKit hands a renewal to every phone
/// on the Apple ID, so the automatic paths send by `RelayAccountCenter.claim`, after a read.
@MainActor
final class RelayAccountClaimTests: XCTestCase {
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

    private func paying(_ bed: AccountBed, _ token: UUID) async throws {
        try await bed.fake.setEntitlement(accountID: token.uuidString.lowercased(), state: "active", for: .seconds(86_400 * 30))
    }

    /// Two phones on one Apple ID over one relay: `a` bought the subscription, `b` has an identity and never held it.
    private func twoPhones() async throws -> (a: AccountBed, b: AccountBed, token: UUID, centerA: RelayAccountCenter) {
        let (a, token) = try await registeredBed()
        let b = AccountBed(sharing: a)
        try await b.register()
        let centerA = await started(a)
        a.sell(a.row(token: token))
        await centerA.buy()
        XCTAssertEqual(centerA.phase, .paying(grace: false, macs: []))
        a.store.unfinishedResult = []
        a.clock.advance(by: .seconds(5))
        return (a, b, token, centerA)
    }

    /// The owner presses Restore on `bed`: the subscription moves there.
    private func restore(on bed: AccountBed, token: UUID) async throws -> RelayAccountCenter {
        let center = await started(bed)
        bed.store.restoreResult = bed.row(id: 5, token: token)
        await center.restore()
        XCTAssertEqual(center.purchase, .done)
        XCTAssertEqual(center.phase, .paying(grace: false, macs: []))
        bed.clock.advance(by: .seconds(5))
        return center
    }

    private func moved(_ center: RelayAccountCenter, _ bed: AccountBed) async {
        await center.refresh()
        XCTAssertEqual(center.phase, .moved)
    }

    func testAMovedPhonesRenewalDoesNotMoveIt() async throws {
        let (a, b, token, centerA) = try await twoPhones()
        let centerB = try await restore(on: b, token: token)
        await moved(centerA, a)
        let sent = a.submitted.count
        let renewal = a.row(id: 2, token: token, renewal: true)
        a.store.unfinishedResult = [renewal]
        let reads = a.reads

        a.store.emit(renewal)
        try await a.until("the delivery's read") { a.reads > reads }
        await foreground(centerA, a)

        XCTAssertEqual(a.submitted.count, sent, "only a press moves it")
        XCTAssertEqual(a.store.finished.filter { $0.id == 2 }, [], "it stays unfinished")
        XCTAssertNil(centerA.unconfirmed, "moved, not \"not confirmed\"")
        XCTAssertEqual(centerA.phase, .moved)
        await centerB.refresh()
        XCTAssertEqual(centerB.phase, .paying(grace: false, macs: []))
    }

    func testAPhoneThatNeverHeldItDoesNotTakeIt() async throws {
        let (a, b, token, centerA) = try await twoPhones()
        let sent = a.submitted.count
        let renewal = a.row(id: 2, token: token, renewal: true)
        b.store.unfinishedResult = [renewal]
        let centerB = await started(b)
        let reads = b.reads
        b.store.emit(renewal)
        try await b.until("the delivery's read") { b.reads > reads }

        XCTAssertEqual(b.submitted.count, sent)
        XCTAssertEqual(centerB.phase, .free(ended: false))
        XCTAssertNil(centerB.unconfirmed)
        XCTAssertEqual(centerB.claim, .unset)
        XCTAssertEqual(b.store.finished, [])
        await centerA.refresh()
        XCTAssertEqual(centerA.phase, .paying(grace: false, macs: []))
    }

    /// Off the network through the move: the next launch learns of it before anything can be sent.
    func testAPhoneOfflineDuringTheMoveDoesNotTakeItAtTheNextLaunch() async throws {
        let (a, b, token, _) = try await twoPhones()
        let centerB = try await restore(on: b, token: token)
        let sent = a.submitted.count
        a.store.unfinishedResult = [a.row(id: 2, token: token, renewal: true)]

        let relaunched = await started(a)

        XCTAssertEqual(a.submitted.count, sent)
        XCTAssertEqual(relaunched.phase, .moved)
        XCTAssertEqual(relaunched.claim, .movedAway)
        XCTAssertNil(relaunched.unconfirmed)
        await centerB.refresh()
        XCTAssertEqual(centerB.phase, .paying(grace: false, macs: []))
    }

    /// StoreKit hands a launch its rows on `updates()` too, ahead of the first foreground: the same read goes first.
    func testADeliveryAtLaunchOnAPhoneOfflineDuringTheMoveDoesNotTakeIt() async throws {
        let (a, b, token, _) = try await twoPhones()
        let centerB = try await restore(on: b, token: token)
        let sent = a.submitted.count
        let renewal = a.row(id: 2, token: token, renewal: true)

        let relaunched = a.makeCenter()
        relaunched.start()
        a.store.emit(renewal)
        try await a.until("the move learned") { relaunched.phase == .moved }

        XCTAssertEqual(a.submitted.count, sent)
        await centerB.refresh()
        XCTAssertEqual(centerB.phase, .paying(grace: false, macs: []))
    }

    func testAnExpirySignalOnAMovedPhoneDoesNotTakeIt() async throws {
        for event in [HostedRelayEvent.control(kind: .entitlementExpired, detail: ""), .entitlementInactive] {
            let (a, b, token, centerA) = try await twoPhones()
            let centerB = try await restore(on: b, token: token)
            let sent = a.submitted.count
            a.store.unfinishedResult = [a.row(id: 2, token: token, renewal: true)]

            a.emit(event)

            try await a.until("the move learned") { centerA.phase == .moved }
            XCTAssertEqual(a.submitted.count, sent, "\(event)")
            await centerB.refresh()
            XCTAssertEqual(centerB.phase, .paying(grace: false, macs: []), "\(event)")
        }
    }

    /// A reinstall loses the defaults and keeps `relay.account`: the old phone's renewal row carries its own token, so only
    /// the read tells it the subscription moved.
    func testAReinstalledOldPhoneDoesNotTakeItBack() async throws {
        let (a, b, token, _) = try await twoPhones()
        let centerB = try await restore(on: b, token: token)
        let sent = a.submitted.count
        a.defaults.removeObject(forKey: RelayAccountCenter.holdsSubscriptionKey)
        let renewal = a.row(id: 2, token: token, renewal: true)
        a.store.unfinishedResult = [renewal]

        let reinstalled = await started(a)

        XCTAssertEqual(a.submitted.count, sent, "only a press moves it")
        XCTAssertEqual(reinstalled.phase, .moved)
        XCTAssertEqual(reinstalled.claim, .movedAway)
        XCTAssertEqual(a.defaults.object(forKey: RelayAccountCenter.holdsSubscriptionKey) as? Bool, false)
        XCTAssertNil(reinstalled.unconfirmed)
        await centerB.refresh()
        XCTAssertEqual(centerB.phase, .paying(grace: false, macs: []))
    }

    /// The same phone and the same row delivered on `updates()`, ahead of the first foreground.
    func testAReinstalledOldPhonesDeliveryDoesNotTakeItBack() async throws {
        let (a, b, token, _) = try await twoPhones()
        let centerB = try await restore(on: b, token: token)
        let sent = a.submitted.count
        a.defaults.removeObject(forKey: RelayAccountCenter.holdsSubscriptionKey)

        let reinstalled = a.makeCenter()
        reinstalled.start()
        a.store.emit(a.row(id: 2, token: token, renewal: true))
        try await a.until("the move learned") { reinstalled.phase == .moved }

        XCTAssertEqual(a.submitted.count, sent)
        await centerB.refresh()
        XCTAssertEqual(centerB.phase, .paying(grace: false, macs: []))
    }

    func testAKilledFirstPurchaseReadsThenSendsThenReads() async throws {
        let (bed, token) = try await registeredBed()
        bed.store.unfinishedResult = [bed.row(token: token)]
        let before = bed.ops.count

        _ = await started(bed)

        let sent = bed.ops.dropFirst(before).filter { $0 != "challenge" && $0 != "login" }
        XCTAssertEqual(sent, ["getAccountState", "submitTransaction", "getAccountState"])
    }

    /// No answer: nothing goes, but a charge this phone may send is still said, on no claim as on a held one.
    func testAFailedReadSendsNothingAndSaysAChargeIsNotReached() async throws {
        for held in [false, true] {
            let (bed, token) = try await registeredBed()
            if held { bed.defaults.set(true, forKey: RelayAccountCenter.holdsSubscriptionKey) }
            let row = bed.row(token: token)
            bed.store.unfinishedResult = [row]
            bed.fake.failNext("getAccountState", with: .unspecified)

            let center = await started(bed)

            XCTAssertEqual(bed.submitted, [], "held \(held)")
            XCTAssertEqual(center.unconfirmed, .notReached, "held \(held)")
            await foreground(center, bed)
            XCTAssertEqual(bed.submitted, [row.jws], "held \(held)")
        }
    }

    /// A moved phone that bought again and did not reach the relay: once it reads moved, nothing will send the row by itself,
    /// so "turns on as soon as Watchtower reaches it" is not true on the card or the banner. The press's own screen keeps its
    /// **Try Again**.
    func testAMovedAnswerClearsAPurchaseNotReached() async throws {
        let (a, b, token, centerA) = try await twoPhones()
        _ = try await restore(on: b, token: token)
        await moved(centerA, a)
        a.sell(a.row(id: 8, token: token))
        a.fake.crash()
        await centerA.buy()
        XCTAssertEqual(centerA.unconfirmed, .notReached)
        a.fake.restart()

        await foreground(centerA, a)

        XCTAssertEqual(centerA.phase, .moved)
        XCTAssertNil(centerA.unconfirmed)
        XCTAssertEqual(centerA.purchase, .boughtNotConfirmed)
    }

    /// Ask to Buy approved in the process that pressed Buy: the press's row goes whatever the claim, and only that row.
    func testAnApprovedPurchaseIsSentOnAMovedPhone() async throws {
        let (a, b, token, centerA) = try await twoPhones()
        let centerB = try await restore(on: b, token: token)
        await moved(centerA, a)
        a.store.purchaseResult = .pending
        await centerA.buy()
        XCTAssertEqual(centerA.purchase, .pending)
        let reads = a.reads
        let sent = a.submitted.count

        a.store.emit(a.row(id: 2, token: token, renewal: true))
        try await a.until("the renewal's read") { a.reads > reads }
        XCTAssertEqual(a.submitted.count, sent, "a renewal is no approval")
        XCTAssertEqual(centerA.purchase, .pending)

        let approved = a.row(id: 9, token: token)
        a.store.emit(approved)
        try await a.until("the approval's answer") { a.store.finished.contains(approved) }
        try await a.until("the screen settled") { centerA.purchase == .done }

        XCTAssertEqual(a.submitted.last, approved.jws)
        XCTAssertEqual(centerA.claim, .holds)
        await centerB.refresh()
        XCTAssertEqual(centerB.phase, .moved)
    }

    func testAKilledFirstPurchaseStillSubmitsAndClaims() async throws {
        let (bed, token) = try await registeredBed()
        let row = bed.row(token: token)
        bed.store.unfinishedResult = [row]

        let center = await started(bed)

        XCTAssertEqual(bed.submitted, [row.jws])
        XCTAssertEqual(center.claim, .holds, "an entitlement answer")
    }

    func testAPressOnAMovedPhoneMovesIt() async throws {
        let (a, b, token, centerA) = try await twoPhones()
        let centerB = try await restore(on: b, token: token)
        await moved(centerA, a)
        XCTAssertEqual(centerA.claim, .movedAway)
        let row = a.row(id: 7, token: token)
        a.store.restoreResult = row

        await centerA.restore()

        XCTAssertEqual(a.submitted.last, row.jws)
        XCTAssertEqual(centerA.purchase, .done)
        XCTAssertEqual(centerA.phase, .paying(grace: false, macs: []))
        XCTAssertEqual(centerA.claim, .holds)
        await centerB.refresh()
        XCTAssertEqual(centerB.phase, .moved)
        XCTAssertEqual(centerB.claim, .movedAway)
    }

    func testTwoPhonesRenewalsDoNotPingPong() async throws {
        let (a, b, token, centerA) = try await twoPhones()
        let centerB = try await restore(on: b, token: token)
        await moved(centerA, a)
        for period in 0..<4 {
            a.clock.advance(by: .seconds(5))
            let renewal = a.row(id: UInt64(10 + period), token: token, renewal: true)
            for bed in [a, b] { bed.store.unfinishedResult = [renewal] }
            let sent = a.submitted.count

            await foreground(centerA, a)
            await foreground(centerB, b)

            XCTAssertEqual(a.submitted.count, sent + 1, "only the holder sends, period \(period)")
            XCTAssertEqual(b.store.finished.last, renewal)
            await centerA.refresh()
            XCTAssertEqual(centerA.phase, .moved, "period \(period)")
            await centerB.refresh()
            XCTAssertEqual(centerB.phase, .paying(grace: false, macs: []), "period \(period)")
        }
    }

    func testTheClaimSurvivesARelaunch() async throws {
        let (a, b, token, centerA) = try await twoPhones()
        XCTAssertEqual(centerA.claim, .holds)
        let centerB = try await restore(on: b, token: token)
        XCTAssertEqual(centerB.claim, .holds)
        await moved(centerA, a)

        XCTAssertEqual(a.defaults.object(forKey: RelayAccountCenter.holdsSubscriptionKey) as? Bool, false)
        XCTAssertEqual(a.makeCenter().claim, .movedAway)
        // The holder's relaunch still sends a row sold to the old account: it holds the subscription now.
        let relaunched = b.makeCenter()
        XCTAssertEqual(relaunched.claim, .holds)
        let renewal = b.row(id: 2, token: token, renewal: true)
        b.store.unfinishedResult = [renewal]
        relaunched.start()
        await relaunched.foreground()?.value
        XCTAssertEqual(b.submitted.last, renewal.jws)
        XCTAssertEqual(b.store.finished.last, renewal)
    }

    func testAMoveControlAndAPayingReadWriteTheClaim() async throws {
        let (bed, token) = try await registeredBed()
        let center = await started(bed)
        XCTAssertEqual(center.claim, .unset, "free: no claim")
        try await paying(bed, token)
        await center.refresh()
        XCTAssertEqual(center.claim, .holds)

        bed.emit(.control(kind: .subscriptionMoved, detail: ""))

        try await bed.until("the control") { center.claim == .movedAway }
    }

    /// A phone with a claim reads first: an order `pass()` keeps on every path.
    func testAClaimReadsBeforeItSends() async throws {
        let (bed, token) = try await registeredBed()
        try await paying(bed, token)
        let center = await started(bed)
        let renewal = bed.row(id: 2, token: token, renewal: true)
        bed.store.unfinishedResult = [renewal]
        let before = bed.ops.count

        await foreground(center, bed)

        XCTAssertEqual(Array(bed.ops.dropFirst(before)), ["getAccountState", "submitTransaction", "getAccountState"])
    }

    /// With a claim and nothing to send, one read is the whole pass.
    func testAClaimWithNothingToSendReadsOnce() async throws {
        let (bed, token) = try await registeredBed()
        try await paying(bed, token)
        let center = await started(bed)
        let before = bed.ops.count

        await foreground(center, bed)

        XCTAssertEqual(Array(bed.ops.dropFirst(before)), ["getAccountState"])
    }

    /// No answer says nothing about a move: nothing goes until a read says it has not moved.
    func testAFailedReadSendsNothingOnAClaim() async throws {
        let (bed, token) = try await registeredBed()
        try await paying(bed, token)
        let center = await started(bed)
        let renewal = bed.row(id: 2, token: token, renewal: true)
        bed.store.unfinishedResult = [renewal]
        // `UNAVAILABLE` is retried on the manual clock: an error that is not, as the read's failure.
        bed.fake.failNext("getAccountState", with: .unspecified)

        await foreground(center, bed)

        XCTAssertEqual(bed.submitted, [])
        XCTAssertEqual(center.phase, .unknown)

        await foreground(center, bed)
        XCTAssertEqual(bed.submitted, [renewal.jws])
    }
}

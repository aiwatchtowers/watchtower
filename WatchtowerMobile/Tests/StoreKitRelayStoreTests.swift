import StoreKit
import StoreKitTest
import XCTest
@testable import WatchtowerMobile

/// The StoreKit seam against Xcode's local StoreKit configuration (`Support/Relay.storekit`). The signed JWS is
/// Xcode-certificate signed, so the relay's own rules are tested on `FakeHostedRelay`, not here.
/// Run it with `make mobile-test`: Xcode's GUI lacks that recipe's test-only signing and fails with an opaque refusal.
final class StoreKitRelayStoreTests: XCTestCase {
    private static let productID = "com.aiwatchtowers.watchtower.relay.monthly"
    private var session: SKTestSession!
    private var store: StoreKitRelayStore!

    /// Whether this process has spoken to storekitd yet (see `setUp`).
    @MainActor private static var storeKitConnected = false

    override func setUp() async throws {
        try await super.setUp()
        // A freshly installed app's first call to storekitd runs storekitd's install handling, which clears the app's
        // StoreKit state. When that first call is the session's configuration save, the clear can land after the save:
        // the client is then bound to the sandbox store with no account, and every purchase in the process hangs. A
        // plain transaction query goes first, so the session is created after the install handling.
        if await !Self.storeKitConnected {
            for await _ in StoreKit.Transaction.unfinished {}
            await MainActor.run { Self.storeKitConnected = true }
        }
        session = try SKTestSession(configurationFileNamed: "Relay")
        // storekitd keeps failTransactionsEnabled and askToBuyEnabled across sessions, and a new session or
        // assigning false does not clear them.
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        store = StoreKitRelayStore(productID: Self.productID)
    }

    override func tearDown() async throws {
        session.clearTransactions()
        session = nil
        store = nil
        try await super.tearDown()
    }

    /// `Transaction.updates` can hand back the purchase itself first: reads on to the event a test is about.
    private static func next(
        _ iterator: inout AsyncStream<RelayTransaction>.AsyncIterator, where wanted: (RelayTransaction) -> Bool
    ) async throws -> RelayTransaction {
        while true {
            let transaction = try await next(&iterator)
            if wanted(transaction) { return transaction }
        }
    }

    /// `updates()` holds StoreKit's iterator from the moment it is called, so an event a test causes afterwards is
    /// delivered and the test needs no head start (it used to sleep two seconds for a subscription made in a task).
    private func listening() -> AsyncStream<RelayTransaction>.AsyncIterator {
        store.updates().makeAsyncIterator()
    }

    /// StoreKit's transaction lists catch up with a purchase shortly after it returns: reads until there is a value.
    private func eventually<Value>(_ read: () async -> Value?) async -> Value? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let value = await read() { return value }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await read()
    }

    func testProductLoadsWithItsPrice() async throws {
        let loaded = try await store.product()
        let product = try XCTUnwrap(loaded)
        XCTAssertEqual(product.id, Self.productID)
        XCTAssertTrue(product.displayPrice.contains("4.99"), product.displayPrice)
    }

    func testAMissingProductIsNil() async throws {
        let missing = StoreKitRelayStore(productID: "com.example.no.such.product")
        let product = try await missing.product()
        XCTAssertNil(product)
    }

    func testPurchaseCarriesTheAccountToken() async throws {
        let token = UUID()
        guard case .purchased(let transaction) = try await store.purchase(accountToken: token) else {
            return XCTFail("expected a purchase")
        }
        XCTAssertFalse(transaction.jws.isEmpty)
        let signed = await eventually { () -> StoreKit.Transaction? in
            for await verification in StoreKit.Transaction.all {
                if case .verified(let value) = verification, value.id == transaction.id { return value }
            }
            return nil
        }
        XCTAssertEqual(signed?.appAccountToken, token)
        XCTAssertEqual(transaction.appAccountToken, token)
    }

    func testAFailedPurchaseThrows() async throws {
        let loaded = try await store.product()
        XCTAssertNotNil(loaded, "a missing product also throws, which is not this test")
        session.failTransactionsEnabled = true
        do {
            _ = try await store.purchase(accountToken: UUID())
            XCTFail("expected a throw")
        } catch {
            XCTAssertNil(error as? RelayStoreError, "expected StoreKit's failure, got \(error)")
        }
    }

    func testAskToBuyIsPending() async throws {
        session.askToBuyEnabled = true
        let result = try await store.purchase(accountToken: UUID())
        XCTAssertEqual(result, .pending)
    }

    func testAnUnfinishedPurchaseIsListedUntilFinished() async throws {
        guard case .purchased(let bought) = try await store.purchase(accountToken: UUID()) else {
            return XCTFail("expected a purchase")
        }
        let before = await eventually { () -> [RelayTransaction]? in
            let listed = await self.store.unfinished()
            return listed.isEmpty ? nil : listed
        }
        XCTAssertEqual(before?.map(\.id), [bought.id])
        await store.finish(bought)
        let after = await store.unfinished()
        XCTAssertTrue(after.isEmpty)
    }

    func testARenewalArrivesOnUpdates() async throws {
        guard case .purchased(let first) = try await store.purchase(accountToken: UUID()) else {
            return XCTFail("expected a purchase")
        }
        await store.finish(first)
        var iterator = listening()
        try session.forceRenewalOfSubscription(productIdentifier: Self.productID)
        let renewal = try await Self.next(&iterator) { $0.id != first.id }
        XCTAssertEqual(renewal.originalID, first.originalID)
        XCTAssertNotEqual(renewal.id, first.id)
        XCTAssertGreaterThan(renewal.expiresAt, first.expiresAt)
    }

    func testARefundIsReportedRevoked() async throws {
        guard case .purchased(let bought) = try await store.purchase(accountToken: UUID()) else {
            return XCTFail("expected a purchase")
        }
        await store.finish(bought)
        XCTAssertFalse(bought.revoked)
        var iterator = listening()
        try session.refundTransaction(identifier: UInt(bought.id))
        let refunded = try await Self.next(&iterator) { $0.revoked }
        XCTAssertEqual(refunded.id, bought.id)
        XCTAssertTrue(refunded.revoked)
    }

    func testATransactionCarriesItsExpiry() async throws {
        guard case .purchased(let bought) = try await store.purchase(accountToken: UUID()) else {
            return XCTFail("expected a purchase")
        }
        let expiry = await eventually { () -> Date? in
            for await verification in StoreKit.Transaction.all {
                if case .verified(let value) = verification, value.id == bought.id { return value.expirationDate }
            }
            return nil
        }
        XCTAssertEqual(bought.expiresAt, expiry)
        XCTAssertGreaterThan(bought.expiresAt, Date())
    }

    func testAUserCancelThrownByThePurchaseIsCancelled() async throws {
        let result = try await StoreKitRelayStore.purchaseResult { throw StoreKitError.userCancelled }
        XCTAssertEqual(result, .cancelled)
    }

    func testAUserCancelThrownByTheRestoreIsCancelled() async {
        do {
            try await StoreKitRelayStore.syncing { throw StoreKitError.userCancelled }
            XCTFail("no throw")
        } catch {
            XCTAssertEqual(error as? RelayStoreError, .cancelled)
        }
    }

    func testAnyOtherStoreThrowPassesThrough() async {
        do {
            _ = try await StoreKitRelayStore.purchaseResult { throw StoreKitError.notEntitled }
            XCTFail("no throw")
        } catch {
            XCTAssertNil(error as? RelayStoreError)
        }
        do {
            try await StoreKitRelayStore.syncing { throw StoreKitError.notEntitled }
            XCTFail("no throw")
        } catch {
            XCTAssertNil(error as? RelayStoreError)
        }
    }

    func testARowWithNoExpiryIsNotATransaction() {
        XCTAssertNil(StoreKitRelayStore.map(
            id: 1, originalID: 1, appAccountToken: nil, jws: "x", revocationDate: nil, isRenewal: false, expirationDate: nil
        ))
        let mapped = StoreKitRelayStore.map(
            id: 2, originalID: 1, appAccountToken: nil, jws: "x", revocationDate: Date(), isRenewal: true,
            expirationDate: Date(timeIntervalSince1970: 9)
        )
        XCTAssertEqual(mapped?.revoked, true)
        XCTAssertEqual(mapped?.isRenewal, true)
        XCTAssertEqual(mapped?.expiresAt, Date(timeIntervalSince1970: 9))
    }

    private func transaction(revoked: Bool = false, expiresAt: Date) -> RelayTransaction {
        RelayTransaction(id: 1, originalID: 1, appAccountToken: nil, jws: "x", revoked: revoked, isRenewal: false, expiresAt: expiresAt)
    }

    func testOnlyAnUnrevokedUnexpiredTransactionIsCurrent() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var graceAsks = 0
        let notInGrace = { () async -> Bool in
            graceAsks += 1
            return false
        }
        let noEntitlement = await StoreKitRelayStore.isCurrent(nil, now: now, inGracePeriod: notInGrace)
        XCTAssertFalse(noEntitlement)
        let revoked = await StoreKitRelayStore.isCurrent(transaction(revoked: true, expiresAt: now + 60), now: now, inGracePeriod: notInGrace)
        XCTAssertFalse(revoked)
        XCTAssertEqual(graceAsks, 0, "grace is asked only past the expiry")
        let expiresNow = await StoreKitRelayStore.isCurrent(transaction(expiresAt: now), now: now, inGracePeriod: notInGrace)
        XCTAssertFalse(expiresNow)
        let expired = await StoreKitRelayStore.isCurrent(transaction(expiresAt: now - 1), now: now, inGracePeriod: notInGrace)
        XCTAssertFalse(expired)
        XCTAssertEqual(graceAsks, 2)
        let current = await StoreKitRelayStore.isCurrent(transaction(expiresAt: now + 1), now: now, inGracePeriod: notInGrace)
        XCTAssertTrue(current)
        XCTAssertEqual(graceAsks, 2, "an unexpired period needs no grace read")
    }

    /// `holdsCurrentEntitlement`'s wiring over faked StoreKit reads: the product asked for, another product's
    /// entitlement, a missing one, and the grace read past the expiry only (review round 2).
    func testTheEntitlementReadAsksForItsProductAndReadsGraceOnlyPastExpiry() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let log = EntitlementLog()
        func reads(_ entry: (productID: String, expiresAt: Date, inGrace: Bool)?) -> RelayEntitlementReads {
            let period = entry.map { transaction(expiresAt: $0.expiresAt) }
            return RelayEntitlementReads { asked in
                log.asked(asked)
                guard let entry else { return nil }
                return RelayEntitlementEntry(productID: entry.productID, transaction: period) {
                    log.graceRead()
                    return entry.inGrace
                }
            }
        }
        let product = Self.productID
        let current = await StoreKitRelayStore.holdsCurrentEntitlement(
            productID: product, now: now, reads: reads((product, now + 60, false)))
        XCTAssertTrue(current)
        XCTAssertEqual(log.products, [product])
        XCTAssertEqual(log.graceReads, 0, "an unexpired period needs no grace read")

        let none = await StoreKitRelayStore.holdsCurrentEntitlement(productID: product, now: now, reads: reads(nil))
        XCTAssertFalse(none)
        let other = await StoreKitRelayStore.holdsCurrentEntitlement(
            productID: product, now: now, reads: reads(("com.example.other", now + 60, true)))
        XCTAssertFalse(other, "another product's entitlement never counts")

        let inGrace = await StoreKitRelayStore.holdsCurrentEntitlement(
            productID: product, now: now, reads: reads((product, now - 60, true)))
        XCTAssertTrue(inGrace)
        let lapsed = await StoreKitRelayStore.holdsCurrentEntitlement(
            productID: product, now: now, reads: reads((product, now - 60, false)))
        XCTAssertFalse(lapsed)
        XCTAssertEqual(log.graceReads, 2)
        XCTAssertEqual(log.products, Array(repeating: product, count: 5))
    }

    /// A subscription past its period in billing grace still entitles the phone; a revoked one never does.
    func testABillingGracePeriodStillCounts() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let inGrace = await StoreKitRelayStore.isCurrent(transaction(expiresAt: now - 60), now: now) { true }
        XCTAssertTrue(inGrace)
        let revokedInGrace = await StoreKitRelayStore.isCurrent(transaction(revoked: true, expiresAt: now - 60), now: now) { true }
        XCTAssertFalse(revokedInGrace)
    }

    func testARenewalIsMarked() async throws {
        guard case .purchased(let first) = try await store.purchase(accountToken: UUID()) else {
            return XCTFail("expected a purchase")
        }
        XCTAssertFalse(first.isRenewal)
        await store.finish(first)
        var iterator = listening()
        try session.forceRenewalOfSubscription(productIdentifier: Self.productID)
        let renewal = try await Self.next(&iterator) { $0.id != first.id }
        XCTAssertTrue(renewal.isRenewal)
    }

    func testASecondPurchaseOfAnActiveSubscriptionChargesNothing() async throws {
        guard case .purchased(let first) = try await store.purchase(accountToken: UUID()) else {
            return XCTFail("expected a purchase")
        }
        await store.finish(first)
        guard case .purchased(let again) = try await store.purchase(accountToken: UUID()) else {
            return XCTFail("StoreKit Testing answers a second buy with the active subscription's transaction")
        }
        XCTAssertEqual(again.id, first.id, "the same transaction, not a new one")
        XCTAssertEqual(again.originalID, first.originalID)
        XCTAssertEqual(again.expiresAt, first.expiresAt, "no new period was bought")
        XCTAssertEqual(session.allTransactions().count, 1, "nothing was charged")
        // currentEntitlements catches up with the purchase shortly after it returns, like the other lists.
        let entitlements = await eventually { () -> Int? in
            var count = 0
            for await verification in StoreKit.Transaction.currentEntitlements {
                if case .verified(let value) = verification, value.productID == Self.productID { count += 1 }
            }
            return count == 0 ? nil : count
        }
        XCTAssertEqual(entitlements, 1)
    }

    /// The stream ended without the update.
    private struct NoUpdate: Error {}

    /// The next update. It waits for StoreKit's event itself, with no clock: on a loaded CI runner storekitd took
    /// 5–22 s per purchase, and a renewal there arrived after the ten-second bound this used to set.
    private static func next(_ iterator: inout AsyncStream<RelayTransaction>.AsyncIterator) async throws -> RelayTransaction {
        guard let value = await iterator.next() else { throw NoUpdate() }
        return value
    }
}

/// What the faked entitlement reads were asked.
private final class EntitlementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var askedProducts: [String] = []
    private var reads = 0

    var products: [String] { lock.withLock { askedProducts } }
    var graceReads: Int { lock.withLock { reads } }

    func asked(_ productID: String) {
        lock.withLock { askedProducts.append(productID) }
    }

    func graceRead() {
        lock.withLock { reads += 1 }
    }
}

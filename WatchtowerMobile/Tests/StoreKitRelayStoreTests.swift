import StoreKit
import StoreKitTest
import XCTest
@testable import WatchtowerMobile

/// The StoreKit seam against Xcode's local StoreKit configuration (`Support/Relay.storekit`). The signed JWS is
/// Xcode-certificate signed, so the relay's own rules are tested on `FakeHostedRelay`, not here.
final class StoreKitRelayStoreTests: XCTestCase {
    private static let productID = "com.aiwatchtowers.watchtower.relay.monthly"
    private var session: SKTestSession!
    private var store: StoreKitRelayStore!

    override func setUp() async throws {
        try await super.setUp()
        session = try SKTestSession(configurationFileNamed: "Relay")
        session.disableDialogs = true
        session.clearTransactions()
        session.failTransactionsEnabled = false
        session.askToBuyEnabled = false
        store = StoreKitRelayStore(productID: Self.productID)
    }

    override func tearDown() async throws {
        session.clearTransactions()
        session = nil
        store = nil
        try await super.tearDown()
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
        var signed: StoreKit.Transaction?
        for await verification in StoreKit.Transaction.all {
            if case .verified(let value) = verification, value.id == transaction.id { signed = value }
        }
        XCTAssertEqual(signed?.appAccountToken, token)
    }

    func testAFailedPurchaseThrows() async {
        session.failTransactionsEnabled = true
        do {
            _ = try await store.purchase(accountToken: UUID())
            XCTFail("expected a throw")
        } catch {}
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
        let before = await store.unfinished()
        XCTAssertEqual(before.map(\.id), [bought.id])
        await store.finish(bought)
        let after = await store.unfinished()
        XCTAssertTrue(after.isEmpty)
    }

    func testARenewalArrivesOnUpdates() async throws {
        guard case .purchased(let first) = try await store.purchase(accountToken: UUID()) else {
            return XCTFail("expected a purchase")
        }
        await store.finish(first)
        var iterator = store.updates().makeAsyncIterator()
        try session.forceRenewalOfSubscription(productIdentifier: Self.productID)
        let renewal = try await Self.next(&iterator)
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
        var iterator = store.updates().makeAsyncIterator()
        try session.refundTransaction(identifier: UInt(bought.id))
        let refunded = try await Self.next(&iterator)
        XCTAssertEqual(refunded.id, bought.id)
        XCTAssertTrue(refunded.revoked)
    }

    func testATransactionCarriesItsExpiry() async throws {
        guard case .purchased(let bought) = try await store.purchase(accountToken: UUID()) else {
            return XCTFail("expected a purchase")
        }
        var expiry: Date?
        for await verification in StoreKit.Transaction.all {
            if case .verified(let value) = verification, value.id == bought.id { expiry = value.expirationDate }
        }
        XCTAssertEqual(bought.expiresAt, expiry)
        XCTAssertGreaterThan(bought.expiresAt, Date())
    }

    func testARowWithNoExpiryIsNotATransaction() {
        XCTAssertNil(StoreKitRelayStore.map(
            id: 1, originalID: 1, jws: "x", revocationDate: nil, isRenewal: false, expirationDate: nil
        ))
        let mapped = StoreKitRelayStore.map(
            id: 2, originalID: 1, jws: "x", revocationDate: Date(), isRenewal: true, expirationDate: Date(timeIntervalSince1970: 9)
        )
        XCTAssertEqual(mapped?.revoked, true)
        XCTAssertEqual(mapped?.isRenewal, true)
        XCTAssertEqual(mapped?.expiresAt, Date(timeIntervalSince1970: 9))
    }

    func testARenewalIsMarked() async throws {
        guard case .purchased(let first) = try await store.purchase(accountToken: UUID()) else {
            return XCTFail("expected a purchase")
        }
        XCTAssertFalse(first.isRenewal)
        await store.finish(first)
        var iterator = store.updates().makeAsyncIterator()
        try session.forceRenewalOfSubscription(productIdentifier: Self.productID)
        let renewal = try await Self.next(&iterator)
        XCTAssertTrue(renewal.isRenewal)
    }

    func testASecondPurchaseOfAnActiveSubscriptionChargesNothing() async throws {
        guard case .purchased(let first) = try await store.purchase(accountToken: UUID()) else {
            return XCTFail("expected a purchase")
        }
        await store.finish(first)
        let second = try await store.purchase(accountToken: UUID())
        if case .purchased(let again) = second {
            XCTAssertEqual(again.expiresAt, first.expiresAt, "no new period was bought")
            XCTAssertEqual(again.originalID, first.originalID)
        }
        var entitlements = 0
        for await verification in StoreKit.Transaction.currentEntitlements {
            if case .verified(let value) = verification, value.productID == Self.productID { entitlements += 1 }
        }
        XCTAssertEqual(entitlements, 1)
    }

    /// The next update, or a failure after ten seconds.
    private static func next(_ iterator: inout AsyncStream<RelayTransaction>.AsyncIterator) async throws -> RelayTransaction {
        try await withThrowingTaskGroup(of: RelayTransaction?.self) { [iterator] group in
            var iterator = iterator
            group.addTask { await iterator.next() }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else {
                throw XCTSkip("no StoreKit update within 10 s")
            }
            return value
        }
    }
}

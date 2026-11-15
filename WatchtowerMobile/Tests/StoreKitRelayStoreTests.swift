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

    override func setUp() async throws {
        try await super.setUp()
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

    /// A test's listener: `updates()`, and a witness reading StoreKit's own `Transaction.updates`, both made in this
    /// call. Each holds StoreKit's iterator from the moment it is made, so an event the test causes afterwards reaches
    /// both, and the test needs no head start (it used to sleep two seconds for a subscription made in a task).
    private struct Listening {
        var updates: AsyncStream<RelayTransaction>.AsyncIterator
        let witness: Witness
    }

    /// What StoreKit itself delivered to this process, read straight from `Transaction.updates`.
    private final class Witness: @unchecked Sendable {
        private struct Source: @unchecked Sendable {
            let iterator: StoreKit.Transaction.Transactions.AsyncIterator
        }

        private let lock = NSLock()
        private var seen: [RelayTransaction] = []
        private var task: Task<Void, Never>?

        init(productID: String) {
            let source = Source(iterator: StoreKit.Transaction.updates.makeAsyncIterator())
            task = Task { [weak self] in
                var iterator = source.iterator
                while let verification = await iterator.next() {
                    guard case .verified(let value) = verification, value.productID == productID,
                          let mapped = StoreKitRelayStore.map(
                              id: value.id, originalID: value.originalID, appAccountToken: value.appAccountToken,
                              jws: verification.jwsRepresentation, revocationDate: value.revocationDate,
                              isRenewal: value.reason == .renewal, expirationDate: value.expirationDate
                          ) else { continue }
                    self?.lock.withLock { self?.seen.append(mapped) }
                }
            }
        }

        deinit { task?.cancel() }

        func saw(_ wanted: (RelayTransaction) -> Bool) -> Bool {
            lock.withLock { seen.contains(where: wanted) }
        }
    }

    private func listening() -> Listening {
        Listening(updates: store.updates().makeAsyncIterator(), witness: Witness(productID: Self.productID))
    }

    /// The event a test is about, from `updates()`. Under load the simulator's storekitd at times pushes nothing to
    /// the test process for the rest of its run: it holds the renewal (`allTransactions()` lists it), yet neither
    /// `Transaction.updates` nor `Transaction.unfinished` in the process ever shows it. When StoreKit's own listener
    /// got nothing either, `updates()` had nothing to deliver, and the test is skipped with that reason; when StoreKit
    /// delivered the event and `updates()` did not pass it on, the test fails.
    private static func next(
        _ listening: inout Listening, where wanted: (RelayTransaction) -> Bool
    ) async throws -> RelayTransaction {
        do {
            return try await next(&listening.updates, where: wanted)
        } catch is NoUpdate where !listening.witness.saw(wanted) {
            throw XCTSkip("StoreKit delivered no update to this test process (a simulator storekitd fault), so updates() had none to pass on")
        }
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
        var listening = listening()
        try session.forceRenewalOfSubscription(productIdentifier: Self.productID)
        let renewal = try await Self.next(&listening) { $0.id != first.id }
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
        var listening = listening()
        try session.refundTransaction(identifier: UInt(bought.id))
        let refunded = try await Self.next(&listening) { $0.revoked }
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

    func testARenewalIsMarked() async throws {
        guard case .purchased(let first) = try await store.purchase(accountToken: UUID()) else {
            return XCTFail("expected a purchase")
        }
        XCTAssertFalse(first.isRenewal)
        await store.finish(first)
        var listening = listening()
        try session.forceRenewalOfSubscription(productIdentifier: Self.productID)
        let renewal = try await Self.next(&listening) { $0.id != first.id }
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

    /// The next update, or a failure after ten seconds.
    private struct NoUpdate: Error {}

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
                throw NoUpdate()
            }
            return value
        }
    }
}

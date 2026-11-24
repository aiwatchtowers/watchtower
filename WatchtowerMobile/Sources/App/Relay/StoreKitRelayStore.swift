import Foundation
import os
import StoreKit

/// The real store: StoreKit 2, one auto-renewable product. Unverified results never become a `RelayTransaction`.
final class StoreKitRelayStore: RelaySubscriptionStore, @unchecked Sendable {
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "RelayStore")

    private let productID: String
    private let lock = NSLock()
    /// Transactions handed out and not yet finished, by id, so `finish` can reach the StoreKit value.
    private var pending: [UInt64: StoreKit.Transaction] = [:]

    init(productID: String) {
        self.productID = productID
    }

    func product() async throws -> RelayProduct? {
        guard let product = try await Product.products(for: [productID]).first else { return nil }
        return RelayProduct(id: product.id, displayPrice: product.displayPrice)
    }

    func purchase(accountToken: UUID) async throws -> RelayPurchaseResult {
        guard let product = try await Product.products(for: [productID]).first else {
            throw RelayStoreError.productUnavailable
        }
        return try await Self.purchaseResult {
            switch try await product.purchase(options: [.appAccountToken(accountToken)]) {
            case .success(let verification):
                guard let transaction = take(verification) else { return .unverified }
                return .purchased(transaction)
            case .pending:
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .cancelled
            }
        }
    }

    func unfinished() async -> [RelayTransaction] {
        var found: [RelayTransaction] = []
        for await verification in Transaction.unfinished {
            if let transaction = take(verification) { found.append(transaction) }
        }
        return found
    }

    func restore() async throws -> RelayTransaction? {
        try await Self.syncing { try await AppStore.sync() }
        guard let verification = await Transaction.currentEntitlement(for: productID) else { return nil }
        return take(verification)
    }

    func updates() -> AsyncStream<RelayTransaction> {
        AsyncStream { continuation in
            // StoreKit's iterator is made here, before `updates()` returns: it buffers from its making, so an event
            // the caller causes after this call is delivered. Made inside the task, it missed events whenever the
            // task started late. It stops with the consumer.
            let source = UpdatesSource(iterator: Transaction.updates.makeAsyncIterator())
            let task = Task { [self] in
                var iterator = source.iterator
                while let verification = await iterator.next() {
                    guard let transaction = take(verification) else { continue }
                    continuation.yield(transaction)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Carries StoreKit's iterator, which is not `Sendable`, into the one task that reads it.
    private struct UpdatesSource: @unchecked Sendable {
        let iterator: Transaction.Transactions.AsyncIterator
    }

    func finish(_ transaction: RelayTransaction) async {
        let stored = lock.withLock { pending.removeValue(forKey: transaction.id) }
        await stored?.finish()
    }

    // MARK: - Mapping

    /// A purchase whose thrown `StoreKitError.userCancelled` is the plain `.cancelled`; any other throw goes on.
    static func purchaseResult(_ body: () async throws -> RelayPurchaseResult) async throws -> RelayPurchaseResult {
        do {
            return try await body()
        } catch StoreKitError.userCancelled {
            return .cancelled
        }
    }

    /// `AppStore.sync()`, whose thrown `StoreKitError.userCancelled` is `RelayStoreError.cancelled`: the seam's word
    /// for it, as only this file imports StoreKit.
    static func syncing(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch StoreKitError.userCancelled {
            throw RelayStoreError.cancelled
        }
    }

    /// A verified transaction as a `RelayTransaction`, remembered for `finish`. Unverified → nil, with a code only.
    private func take(_ verification: VerificationResult<StoreKit.Transaction>) -> RelayTransaction? {
        guard let transaction = Self.verified(verification), transaction.productID == productID,
              let mapped = Self.mapped(transaction, jws: verification.jwsRepresentation) else { return nil }
        lock.withLock { pending[mapped.id] = transaction }
        return mapped
    }

    /// The transaction of a verified result; unverified → nil, logged with a code only.
    fileprivate static func verified(_ verification: VerificationResult<StoreKit.Transaction>) -> StoreKit.Transaction? {
        guard case .verified(let transaction) = verification else {
            logger.error("relay store: unverified transaction skipped")
            return nil
        }
        return transaction
    }

    /// `map` of a StoreKit transaction; one without expiry → nil, logged with a code only.
    fileprivate static func mapped(_ transaction: StoreKit.Transaction, jws: String) -> RelayTransaction? {
        guard let mapped = map(
            id: transaction.id, originalID: transaction.originalID, appAccountToken: transaction.appAccountToken,
            jws: jws,
            revocationDate: transaction.revocationDate, isRenewal: transaction.reason == .renewal,
            expirationDate: transaction.expirationDate
        ) else {
            logger.error("relay store: transaction without expiry skipped")
            return nil
        }
        return mapped
    }

    /// Whether this device holds a current entitlement to `productID`, from StoreKit's on-device record only: no
    /// `AppStore.sync()`, so it never asks for an Apple ID. A device whose purchases were never restored answers false.
    /// A period past its expiry still counts while StoreKit reports the subscription in its billing grace period
    /// (`Transaction.subscriptionStatus`, which StoreKit answers without a sign-in; the caller bounds the read).
    static func holdsCurrentEntitlement(productID: String, now: Date, reads: RelayEntitlementReads = .live) async -> Bool {
        guard let entry = await reads.currentEntitlement(productID), entry.productID == productID else { return false }
        return await isCurrent(entry.transaction, now: now, inGracePeriod: entry.inGracePeriod)
    }

    /// A transaction that is not revoked and is either before its expiry or, past it, in billing grace
    /// (`inGracePeriod`, asked only then).
    static func isCurrent(_ transaction: RelayTransaction?, now: Date, inGracePeriod: () async -> Bool) async -> Bool {
        guard let transaction, !transaction.revoked else { return false }
        return transaction.expiresAt > now ? true : await inGracePeriod()
    }

    /// The plain-field mapping. A transaction with no expiry is not a subscription period: nil.
    static func map(
        id: UInt64, originalID: UInt64, appAccountToken: UUID?, jws: String, revocationDate: Date?, isRenewal: Bool, expirationDate: Date?
    ) -> RelayTransaction? {
        guard let expirationDate else { return nil }
        return RelayTransaction(
            id: id, originalID: originalID, appAccountToken: appAccountToken, jws: jws, revoked: revocationDate != nil, isRenewal: isRenewal,
            expiresAt: expirationDate
        )
    }
}

/// A verified current entitlement as StoreKit holds it: its product, its period (nil without an expiry), and the
/// read of its billing grace.
struct RelayEntitlementEntry: Sendable {
    let productID: String
    let transaction: RelayTransaction?
    let inGracePeriod: @Sendable () async -> Bool
}

/// The StoreKit reads behind `StoreKitRelayStore.holdsCurrentEntitlement`: `Transaction.currentEntitlement(for:)`
/// (verified only) and the entitlement's `subscriptionStatus`. Tests pass fakes.
struct RelayEntitlementReads: Sendable {
    var currentEntitlement: @Sendable (_ productID: String) async -> RelayEntitlementEntry?

    static let live = Self { productID in
        guard let verification = await Transaction.currentEntitlement(for: productID),
              let transaction = StoreKitRelayStore.verified(verification) else { return nil }
        return RelayEntitlementEntry(
            productID: transaction.productID,
            transaction: StoreKitRelayStore.mapped(transaction, jws: verification.jwsRepresentation)
        ) {
            await transaction.subscriptionStatus?.state == .inGracePeriod
        }
    }
}

enum RelayStoreError: Error, Equatable {
    case productUnavailable
    /// The owner cancelled the App Store sign-in of a restore.
    case cancelled
}

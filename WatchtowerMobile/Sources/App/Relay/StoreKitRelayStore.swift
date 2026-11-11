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
            // The StoreKit stream starts here, on first use, and stops with the consumer.
            let task = Task { [self] in
                for await verification in Transaction.updates {
                    guard let transaction = take(verification) else { continue }
                    continuation.yield(transaction)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
        guard case .verified(let transaction) = verification else {
            Self.logger.error("relay store: unverified transaction skipped")
            return nil
        }
        guard transaction.productID == productID else { return nil }
        guard let mapped = Self.map(
            id: transaction.id, originalID: transaction.originalID, appAccountToken: transaction.appAccountToken,
            jws: verification.jwsRepresentation,
            revocationDate: transaction.revocationDate, isRenewal: transaction.reason == .renewal,
            expirationDate: transaction.expirationDate
        ) else {
            Self.logger.error("relay store: transaction without expiry skipped")
            return nil
        }
        lock.withLock { pending[mapped.id] = transaction }
        return mapped
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

enum RelayStoreError: Error, Equatable {
    case productUnavailable
    /// The owner cancelled the App Store sign-in of a restore.
    case cancelled
}

import Foundation

/// The Relay subscription's one product, as the store lists it.
struct RelayProduct: Equatable, Sendable {
    let id: String
    let displayPrice: String
}

/// One signed App Store transaction, reduced to what the relay account needs. `jws` is the secret: it is never logged
/// and never part of an error's description.
struct RelayTransaction: Equatable, Sendable {
    let id: UInt64
    let originalID: UInt64
    let jws: String
    let revoked: Bool
    /// `Transaction.reason == .renewal`.
    let isRenewal: Bool
    let expiresAt: Date
}

enum RelayPurchaseResult: Equatable, Sendable {
    case purchased(RelayTransaction)
    case pending
    case cancelled
    /// The store returned a transaction that failed its signature check; it is never used.
    case unverified
}

/// Everything the phone needs from StoreKit, behind one seam. Only `StoreKitRelayStore` imports StoreKit.
protocol RelaySubscriptionStore: Sendable {
    func product() async throws -> RelayProduct?
    func purchase(accountToken: UUID) async throws -> RelayPurchaseResult
    func unfinished() async -> [RelayTransaction]
    /// `AppStore.sync()`, then the current entitlement's fresh transaction. The owner's cancel throws
    /// `RelayStoreError.cancelled`.
    func restore() async throws -> RelayTransaction?
    func updates() -> AsyncStream<RelayTransaction>
    func finish(_ transaction: RelayTransaction) async
}

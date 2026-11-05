import Foundation
@testable import WatchtowerMobile

/// A scripted `RelaySubscriptionStore`: tests set what each call returns and read what was asked.
final class FakeSubscriptionStore: RelaySubscriptionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state = State()

    private struct State {
        var product: RelayProduct?
        var productError: Error?
        var purchaseResult: RelayPurchaseResult = .cancelled
        var purchaseError: Error?
        var unfinished: [RelayTransaction] = []
        var restoreResult: RelayTransaction?
        var restoreError: Error?
        var accountTokens: [UUID] = []
        var finished: [RelayTransaction] = []
        var restoreCalls = 0
        var updatesCalls = 0
        var continuation: AsyncStream<RelayTransaction>.Continuation?
    }

    var productResult: RelayProduct? {
        get { lock.withLock { state.product } }
        set { lock.withLock { state.product = newValue } }
    }
    var productError: Error? {
        get { lock.withLock { state.productError } }
        set { lock.withLock { state.productError = newValue } }
    }
    var purchaseResult: RelayPurchaseResult {
        get { lock.withLock { state.purchaseResult } }
        set { lock.withLock { state.purchaseResult = newValue } }
    }
    var purchaseError: Error? {
        get { lock.withLock { state.purchaseError } }
        set { lock.withLock { state.purchaseError = newValue } }
    }
    var unfinishedResult: [RelayTransaction] {
        get { lock.withLock { state.unfinished } }
        set { lock.withLock { state.unfinished = newValue } }
    }
    var restoreResult: RelayTransaction? {
        get { lock.withLock { state.restoreResult } }
        set { lock.withLock { state.restoreResult = newValue } }
    }
    var restoreError: Error? {
        get { lock.withLock { state.restoreError } }
        set { lock.withLock { state.restoreError = newValue } }
    }
    var accountTokens: [UUID] { lock.withLock { state.accountTokens } }
    var finished: [RelayTransaction] { lock.withLock { state.finished } }
    var restoreCalls: Int { lock.withLock { state.restoreCalls } }
    var updatesCalls: Int { lock.withLock { state.updatesCalls } }

    /// Delivers a transaction on the `updates()` stream, if one is open.
    func emit(_ transaction: RelayTransaction) {
        lock.withLock { state.continuation }?.yield(transaction)
    }

    func product() async throws -> RelayProduct? {
        let (product, error) = lock.withLock { (state.product, state.productError) }
        if let error { throw error }
        return product
    }

    func purchase(accountToken: UUID) async throws -> RelayPurchaseResult {
        let (result, error) = lock.withLock { () -> (RelayPurchaseResult, Error?) in
            state.accountTokens.append(accountToken)
            return (state.purchaseResult, state.purchaseError)
        }
        if let error { throw error }
        return result
    }

    func unfinished() async -> [RelayTransaction] {
        lock.withLock { state.unfinished }
    }

    func restore() async throws -> RelayTransaction? {
        let (result, error) = lock.withLock { () -> (RelayTransaction?, Error?) in
            state.restoreCalls += 1
            return (state.restoreResult, state.restoreError)
        }
        if let error { throw error }
        return result
    }

    func updates() -> AsyncStream<RelayTransaction> {
        AsyncStream { continuation in
            lock.withLock {
                state.updatesCalls += 1
                state.continuation = continuation
            }
        }
    }

    func finish(_ transaction: RelayTransaction) async {
        lock.withLock { state.finished.append(transaction) }
    }
}

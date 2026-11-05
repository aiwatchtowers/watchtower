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
        var productCalls = 0
        var unfinishedCalls = 0
        var onPurchase: (@Sendable (UUID) -> RelayPurchaseResult)?
        var onFinish: (@Sendable () -> Void)?
        var purchaseParked = false
        var parkedPurchase: CheckedContinuation<Void, Never>?
        var productParked = false
        var parkedProduct: CheckedContinuation<Void, Never>?
        var restoreParked = false
        var parkedRestore: CheckedContinuation<Void, Never>?
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
    var productCalls: Int { lock.withLock { state.productCalls } }
    var unfinishedCalls: Int { lock.withLock { state.unfinishedCalls } }
    /// Every call the store took, of any kind.
    var totalCalls: Int {
        lock.withLock {
            state.productCalls + state.unfinishedCalls + state.restoreCalls + state.updatesCalls + state.accountTokens.count
                + state.finished.count
        }
    }
    /// Answers `purchase` from the token it was given (the JWS carries it); nil uses `purchaseResult`.
    var onPurchase: (@Sendable (UUID) -> RelayPurchaseResult)? {
        get { lock.withLock { state.onPurchase } }
        set { lock.withLock { state.onPurchase = newValue } }
    }
    /// Runs inside `finish`, for the order on the fakes.
    var onFinish: (@Sendable () -> Void)? {
        get { lock.withLock { state.onFinish } }
        set { lock.withLock { state.onFinish = newValue } }
    }
    /// A purchase is waiting at `parkPurchase()`.
    var purchaseIsParked: Bool { lock.withLock { state.parkedPurchase != nil } }

    /// The next `purchase` waits until `releasePurchase()`: the App Store's sheet on screen.
    func parkPurchase() {
        lock.withLock { state.purchaseParked = true }
    }

    /// A product load is waiting at `parkProduct()`.
    var productIsParked: Bool { lock.withLock { state.parkedProduct != nil } }

    /// The next `product` waits until `releaseProduct()`.
    func parkProduct() {
        lock.withLock { state.productParked = true }
    }

    func releaseProduct() {
        let waiter = lock.withLock {
            state.productParked = false
            defer { state.parkedProduct = nil }
            return state.parkedProduct
        }
        waiter?.resume()
    }

    /// A restore is waiting at `parkRestore()`.
    var restoreIsParked: Bool { lock.withLock { state.parkedRestore != nil } }

    /// The next `restore` waits until `releaseRestore()`: the App Store's sign-in on screen.
    func parkRestore() {
        lock.withLock { state.restoreParked = true }
    }

    func releaseRestore() {
        let waiter = lock.withLock {
            state.restoreParked = false
            defer { state.parkedRestore = nil }
            return state.parkedRestore
        }
        waiter?.resume()
    }

    func releasePurchase() {
        let waiter = lock.withLock {
            state.purchaseParked = false
            defer { state.parkedPurchase = nil }
            return state.parkedPurchase
        }
        waiter?.resume()
    }

    /// Delivers a transaction on the `updates()` stream, if one is open.
    func emit(_ transaction: RelayTransaction) {
        lock.withLock { state.continuation }?.yield(transaction)
    }

    func product() async throws -> RelayProduct? {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let parked = lock.withLock {
                guard state.productParked else { return false }
                state.parkedProduct = waiter
                return true
            }
            if !parked { waiter.resume() }
        }
        let (product, error) = lock.withLock { () -> (RelayProduct?, Error?) in
            state.productCalls += 1
            return (state.product, state.productError)
        }
        if let error { throw error }
        return product
    }

    func purchase(accountToken: UUID) async throws -> RelayPurchaseResult {
        await waitWhileParked()
        let (result, error) = lock.withLock { () -> (RelayPurchaseResult, Error?) in
            state.accountTokens.append(accountToken)
            return (state.onPurchase?(accountToken) ?? state.purchaseResult, state.purchaseError)
        }
        if let error { throw error }
        return result
    }

    func unfinished() async -> [RelayTransaction] {
        lock.withLock {
            state.unfinishedCalls += 1
            return state.unfinished
        }
    }

    func restore() async throws -> RelayTransaction? {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let parked = lock.withLock {
                guard state.restoreParked else { return false }
                state.parkedRestore = waiter
                return true
            }
            if !parked { waiter.resume() }
        }
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

    /// As StoreKit: a finished transaction leaves `unfinished`.
    func finish(_ transaction: RelayTransaction) async {
        let onFinish = lock.withLock { () -> (@Sendable () -> Void)? in
            state.finished.append(transaction)
            state.unfinished.removeAll { $0.id == transaction.id }
            return state.onFinish
        }
        onFinish?()
    }

    private func waitWhileParked() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let parked = lock.withLock {
                guard state.purchaseParked else { return false }
                state.parkedPurchase = waiter
                return true
            }
            if !parked { waiter.resume() }
        }
    }
}

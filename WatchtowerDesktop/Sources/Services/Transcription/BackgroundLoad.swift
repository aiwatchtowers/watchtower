import Foundation

/// A load (a model, typically one that may download first) that runs in the
/// background and that a caller waits for only so long (board #564): a
/// caller past its wait gets nil and goes on without the value while the
/// load keeps running, and the next caller picks the value up once it is
/// there. One load at a time; a finished value is kept. A failed load is
/// not remembered: the failure goes to the caller waiting on it (or the next
/// caller, so it is never lost), and a new load starts as it is thrown.
actor BackgroundLoad<Value: Sendable> {
    private let load: @Sendable () async throws -> Value
    private var value: Value?
    private var failure: Error?
    private var running: Task<Void, Never>?
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiter = 0

    init(_ load: @escaping @Sendable () async throws -> Value) {
        self.load = load
    }

    /// The value, starting the load when none runs; nil when it is still
    /// loading after `wait` (nil `wait` = until it finishes). Throws the
    /// load's error.
    func value(waitingUpTo wait: Duration?) async throws -> Value? {
        if let value { return value }
        if failure == nil, running == nil { start() }
        if running != nil { await waitForLoad(upTo: wait) }
        if let value { return value }
        if let failure {
            self.failure = nil
            start()
            throw failure
        }
        return nil
    }

    private func start() {
        running = Task {
            do {
                finish(.success(try await load()))
            } catch {
                finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<Value, Error>) {
        running = nil
        switch result {
        case let .success(loaded): value = loaded
        case let .failure(error): failure = error
        }
        let pending = waiters.values
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    private func waitForLoad(upTo wait: Duration?) async {
        let id = nextWaiter
        nextWaiter += 1
        await withCheckedContinuation { continuation in
            waiters[id] = continuation
            if let wait {
                Task {
                    try? await Task.sleep(for: wait)
                    stopWaiting(id)
                }
            }
        }
    }

    private func stopWaiting(_ id: Int) {
        waiters.removeValue(forKey: id)?.resume()
    }
}

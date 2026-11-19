import Foundation

/// Counts arrivals; `until(n)` returns once `n` have arrived (no deadline).
actor Arrivals {
    private var count = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func arrive() {
        count += 1
        let ready = waiters.filter { $0.count <= count }
        waiters.removeAll { $0.count <= count }
        ready.forEach { $0.continuation.resume() }
    }

    func until(_ target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }
}

/// A sleeper that never ends on its own: it returns when its task is cancelled.
func untilCancelled() async {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    for await _ in stream {}
    continuation.finish()
}

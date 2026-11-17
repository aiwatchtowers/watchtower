import Foundation

/// Holds every `chat.*` command a `FakeChatTower` applies until `release()`:
/// the daemon's write is still on its way, as `HeldWriter` held the
/// in-process writer before the chat writes moved to Go.
package final class TowerHold: @unchecked Sendable {
    private let lock = NSLock()
    private var held = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    package init(_ tower: FakeChatTower) {
        tower.beforeApply = { [self] _ in await wait() }
    }

    private func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                guard held else { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Lets every held and later command through.
    package func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            held = false
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }
}

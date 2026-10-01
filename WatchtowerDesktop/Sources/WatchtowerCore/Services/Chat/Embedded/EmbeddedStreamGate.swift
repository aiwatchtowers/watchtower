import Foundation
import Observation

/// App-wide cap on concurrent embedded-chat turns (each is one `ai query`
/// process tree). A turn past the cap waits, first come first served, and
/// its engine shows it as queued. The main chat's session pool is separate.
@MainActor
@Observable
package final class EmbeddedStreamGate {
    package let limit: Int
    package private(set) var active: Set<UUID> = []
    @ObservationIgnored private var waiters: [(id: UUID, onGranted: () -> Void)] = []

    package init(limit: Int = 3) {
        self.limit = max(1, limit)
    }

    package var waiting: Int { waiters.count }

    /// Takes a slot now if one is free.
    package func tryAcquire(_ id: UUID) -> Bool {
        if active.contains(id) { return true }
        guard active.count < limit else { return false }
        active.insert(id)
        return true
    }

    /// Waits for a slot; `onGranted` runs once the slot is held.
    package func enqueue(_ id: UUID, onGranted: @escaping () -> Void) {
        guard !waiters.contains(where: { $0.id == id }) else { return }
        waiters.append((id, onGranted))
    }

    /// Withdraws a waiter that has not been granted yet.
    package func cancel(_ id: UUID) {
        waiters.removeAll { $0.id == id }
    }

    /// Frees a slot and hands it to the oldest waiter. Releasing a slot that
    /// is not held is a no-op.
    package func release(_ id: UUID) {
        guard active.remove(id) != nil else { return }
        while active.count < limit, !waiters.isEmpty {
            let next = waiters.removeFirst()
            active.insert(next.id)
            next.onGranted()
        }
    }
}

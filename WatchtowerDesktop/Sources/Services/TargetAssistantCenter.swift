import Foundation
import WatchtowerCore

/// App-wide registry of target assistant containers, keyed by target id, living
/// on `AppState` so an agent that is mid-turn keeps working after the operator
/// leaves the target screen (house rule: async operations survive navigation —
/// a view-local container would tear the stream down on navigation).
///
/// Bounded: at most `limit` containers are kept, least-recently-used first out.
/// A container is only ever evicted while none of its chat VMs is streaming, so
/// the bound can never kill a working agent — a busy container simply stays
/// until it goes idle.
@MainActor
@Observable
final class TargetAssistantCenter {
    typealias ContainerFactory = (Target, TargetsViewModel, DatabaseManager) -> TargetAssistantViewModel

    private var containers: [Int: TargetAssistantViewModel] = [:]
    /// Target ids in use order, least-recently-used first.
    private var usage: [Int] = []
    private let limit: Int
    private let factory: ContainerFactory

    init(limit: Int = 4, factory: ContainerFactory? = nil) {
        self.limit = max(1, limit)
        self.factory = factory ?? { target, viewModel, dbManager in
            TargetAssistantViewModel(target: target, viewModel: viewModel, dbManager: dbManager)
        }
    }

    /// Number of containers currently held (tests and diagnostics).
    var count: Int { containers.count }

    /// The container for a target if one is already held — never creates one.
    func loaded(_ targetID: Int) -> TargetAssistantViewModel? { containers[targetID] }

    /// The target's container, created on first use. Marks it most-recently-used
    /// and trims the registry back to `limit` afterwards.
    func container(
        for target: Target,
        viewModel: TargetsViewModel,
        dbManager: DatabaseManager
    ) -> TargetAssistantViewModel {
        let container = containers[target.id] ?? factory(target, viewModel, dbManager)
        containers[target.id] = container
        touch(target.id)
        evictIfNeeded()
        return container
    }

    /// Drops a target's container outright — the target was deleted, so its
    /// conversations are gone by the existing delete path and nothing the
    /// container holds is worth keeping.
    func drop(targetID: Int) {
        containers[targetID]?.stop()
        containers[targetID] = nil
        usage.removeAll { $0 == targetID }
    }

    private func touch(_ targetID: Int) {
        usage.removeAll { $0 == targetID }
        usage.append(targetID)
    }

    /// Trims to `limit`, oldest first, skipping any container with a streaming
    /// VM and the most recently used one. Iterating the array copy is safe:
    /// Swift arrays are values, so removing from `usage` inside the loop does
    /// not disturb the iteration.
    private func evictIfNeeded() {
        guard containers.count > limit else { return }
        let mostRecent = usage.last
        for targetID in usage {
            guard containers.count > limit else { return }
            guard targetID != mostRecent,
                  let container = containers[targetID],
                  !container.isAnyWorking else { continue }
            // Idle by the guard above, so this only ends the tabs' GRDB
            // observations — nothing in flight is interrupted.
            container.stop()
            containers[targetID] = nil
            usage.removeAll { $0 == targetID }
        }
    }
}

import Foundation
import GRDB

/// Drives the observer timeline + management UI on a target's detail view.
/// Observes `observers` + `observer_events` for the target and applies a
/// confirmed proposed action through the shared (static) `TargetActionExecutor`,
/// reusing the same Target + TargetsViewModel the chat path uses.
@MainActor
@Observable
final class ObserverTimelineViewModel {
    let target: Target
    private let dbPool: DatabasePool
    private let targetsViewModel: TargetsViewModel
    private let observeService: TargetObserveService

    var observers: [Observer] = []
    var events: [ObserverEvent] = []
    var isRefreshing = false
    var errorMessage: String?

    private var observationTask: Task<Void, Never>?

    init(target: Target, dbManager: DatabaseManager,
         targetsViewModel: TargetsViewModel, observeService: TargetObserveService) {
        self.target = target
        self.dbPool = dbManager.dbPool
        self.targetsViewModel = targetsViewModel
        self.observeService = observeService
    }

    func start() {
        let id = target.id
        let dbPool = self.dbPool
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            let observation = ValueObservation.tracking { db -> ([Observer], [ObserverEvent]) in
                let obs = try ObserverQueries.fetchForEntity(db, entityId: id)
                let evs = try ObserverQueries.fetchEvents(db, entityId: id)
                return (obs, evs)
            }
            do {
                for try await result in observation.values(in: dbPool) {
                    guard let self else { return }
                    self.observers = result.0
                    self.events = result.1
                }
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func refreshNow() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            _ = try await observeService.run(targetID: target.id)
            // The CLI wrote rows; the ValueObservation stream pushes them.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markRead(_ event: ObserverEvent) {
        guard event.isUnread else { return }
        try? dbPool.write { db in try ObserverQueries.markRead(db, id: event.id) }
    }

    /// Applies a confirmed proposed action via the shared static executor, then
    /// records the event's action_status so the button does not re-fire.
    func applyAction(for event: ObserverEvent) {
        guard let action = event.decodedAction else { return }
        do {
            _ = try TargetActionExecutor.apply(action, target: target, viewModel: targetsViewModel)
            try dbPool.write { db in
                try ObserverQueries.setActionStatus(db, id: event.id, status: "applied")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissAction(for event: ObserverEvent) {
        do {
            try dbPool.write { db in
                try ObserverQueries.setActionStatus(db, id: event.id, status: "dismissed")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Cancels the GRDB observation. Call from the view's onDisappear / before
    /// replacing the VM, since a @MainActor deinit cannot touch the task.
    func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    // Observer management
    func createObserver(name: String, instruction: String) {
        try? dbPool.write { db in
            _ = try ObserverQueries.create(db, entityId: target.id, name: name, instruction: instruction)
        }
    }

    func updateObserver(_ o: Observer, name: String, instruction: String) {
        try? dbPool.write { db in try ObserverQueries.update(db, id: o.id, name: name, instruction: instruction) }
    }

    func toggleObserver(_ o: Observer) {
        try? dbPool.write { db in try ObserverQueries.setEnabled(db, id: o.id, enabled: !o.enabled) }
    }

    func deleteObserver(_ o: Observer) {
        try? dbPool.write { db in try ObserverQueries.delete(db, id: o.id) }
    }
}

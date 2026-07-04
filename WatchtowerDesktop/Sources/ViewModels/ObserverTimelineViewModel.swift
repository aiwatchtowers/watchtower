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
    /// Non-nil while a history backfill runs — drives the visible "Scanning…"
    /// banner so the long (multi-minute) operation is unmistakably in progress.
    var scanStatus: String?
    var errorMessage: String?

    private var observationTask: Task<Void, Never>?

    init(target: Target,
         dbManager: DatabaseManager,
         targetsViewModel: TargetsViewModel,
         observeService: TargetObserveService) {
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

    /// Backfills the timeline by scanning history from `since` (nil = all history)
    /// up to now, deduping against existing events. `label` describes the range
    /// for the in-progress banner. The scan runs several AI calls and can take a
    /// few minutes, so `scanStatus` stays set for the whole duration.
    func scanHistory(since: Date?, label: String) async {
        isRefreshing = true
        scanStatus = "Scanning \(label)… this can take a few minutes"
        errorMessage = nil
        defer { isRefreshing = false; scanStatus = nil }
        let iso = Self.isoFormatter.string(from: since ?? Date(timeIntervalSince1970: 0))
        do {
            _ = try await observeService.run(targetID: target.id, since: iso)
        } catch {
            errorMessage = "History scan failed: \(error.localizedDescription)"
        }
    }

    /// UTC ISO8601 without fractional seconds, matching the Go watermark format.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Resolves an external "open the source" link for an event: an explicit
    /// source_ref if present, else a resolved permalink for the underlying entity
    /// (e.g. the Slack link of an inbox-sourced event). Returns nil when none.
    func sourceLink(for event: ObserverEvent) -> String? {
        if let first = event.decodedRefs.first, !first.isEmpty { return first }
        return try? dbPool.read { db in
            try ObserverQueries.sourcePermalink(db, sourceType: event.sourceType, sourceId: event.sourceId)
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
            // Apply against a FRESH copy of the target, not the init-time
            // snapshot: the executor's sub-item/note paths are whole-JSON
            // read-modify-writes, so a stale snapshot would clobber anything
            // applied since this VM was created (lost update).
            let fresh = try dbPool.read { db in
                try TargetQueries.fetchByID(db, id: target.id)
            } ?? target
            _ = try TargetActionExecutor.apply(action, target: fresh, viewModel: targetsViewModel)
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

    /// Drafts a scoped observer (name + instruction) from a free-text request
    /// via the CLI. Returns nil and sets `errorMessage` on failure.
    func compose(input: String) async -> ObserverDraft? {
        guard let runner = ProcessCLIRunner.makeDefault() else {
            errorMessage = "watchtower CLI not found in PATH"
            return nil
        }
        do {
            return try await ObserverComposeService(runner: runner).compose(targetID: target.id, input: input)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // Observer management
    func createObserver(name: String, instruction: String) {
        do {
            try dbPool.write { db in
                _ = try ObserverQueries.create(db, entityId: target.id, name: name, instruction: instruction)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateObserver(_ observer: Observer, name: String, instruction: String) {
        do {
            try dbPool.write { db in
                try ObserverQueries.update(db, id: observer.id, name: name, instruction: instruction)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleObserver(_ observer: Observer) {
        do {
            try dbPool.write { db in
                try ObserverQueries.setEnabled(db, id: observer.id, enabled: !observer.enabled)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteObserver(_ observer: Observer) {
        do {
            try dbPool.write { db in try ObserverQueries.delete(db, id: observer.id) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

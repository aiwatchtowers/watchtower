import Foundation
import GRDB

/// Drives the target's "Watch" tab: the watches linked to the target, the
/// origin track it was promoted from (if any), and the merged activity feed
/// from all its watches. Applies a confirmed proposed action to THIS target.
@MainActor
@Observable
final class TargetWatchesViewModel {
    let target: Target
    private let dbPool: DatabasePool
    private let scanCenter: TrackScanCenter
    private let targetsViewModel: TargetsViewModel
    private let scanService: TrackScanService

    var watches: [Track] = []
    var originTrack: Track?
    var events: [TrackEvent] = []
    var errorMessage: String?

    private var watchesTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?

    init(target: Target,
         dbManager: DatabaseManager,
         scanService: TrackScanService,
         targetsViewModel: TargetsViewModel,
         scanCenter: TrackScanCenter) {
        self.target = target
        self.dbPool = dbManager.dbPool
        self.scanService = scanService
        self.targetsViewModel = targetsViewModel
        self.scanCenter = scanCenter
    }

    /// Human label for a feed event's source watch.
    func watchName(for trackID: Int) -> String {
        watches.first { $0.id == trackID }?.text ?? "Watch"
    }

    func start() {
        loadOriginTrack()
        let id = target.id
        let pool = dbPool
        watchesTask?.cancel()
        watchesTask = Task { [weak self] in
            let obs = ValueObservation.tracking { db in
                try TrackQueries.fetchByLinkedTarget(db, targetID: id)
            }
            do {
                for try await rows in obs.values(in: pool) {
                    guard let self else { return }
                    self.watches = rows
                }
            } catch { self?.errorMessage = error.localizedDescription }
        }
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            let obs = ValueObservation.tracking { db in
                try TrackEventQueries.fetchForTarget(db, targetID: id)
            }
            do {
                for try await rows in obs.values(in: pool) {
                    guard let self else { return }
                    self.events = rows
                }
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func stop() {
        watchesTask?.cancel(); watchesTask = nil
        eventsTask?.cancel(); eventsTask = nil
    }

    private func loadOriginTrack() {
        guard target.sourceType == "track", let tid = Int(target.sourceID) else {
            originTrack = nil
            return
        }
        originTrack = try? dbPool.read { db in try TrackQueries.fetchByID(db, id: tid) }
    }

    // MARK: - Scanning

    func isScanning(_ trackID: Int) -> Bool { scanCenter.isRunning(trackID) }

    /// Scans one watch over the given range (nil since = all history), tracked
    /// in the shared center so the indicator survives navigation.
    func scanWatch(_ watch: Track, since: Date?, label: String) async {
        scanCenter.begin(watch.id)
        var note: String?
        defer { scanCenter.finish(watch.id, note: note) }
        do {
            let iso = since.map { Self.isoFormatter.string(from: $0) }
            let created = try await scanService.run(trackID: watch.id, since: iso)
            note = created.isEmpty
                ? "\(watch.text): no new activity (\(label))."
                : "\(watch.text): \(created.count) new update(s)."
        } catch {
            note = "\(watch.text): scan failed — \(error.localizedDescription)"
            errorMessage = error.localizedDescription
        }
    }

    /// Scans every enabled watch of the target (concurrently is unnecessary —
    /// each is a slow subprocess; run them in sequence to keep it simple).
    func scanAll() async {
        for w in watches where w.enabled {
            await scanWatch(w, since: nil, label: "all history")
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: - Feed actions

    /// Every feed event originates from a watch linked to this target, so a
    /// confirmed proposed action always has a target to mutate.
    var canApplyActions: Bool { true }

    func applyAction(for event: TrackEvent) {
        guard let action = event.decodedAction else { return }
        do {
            guard let fresh = try dbPool.read({ db in try TargetQueries.fetchByID(db, id: target.id) }) else {
                errorMessage = "This target no longer exists — it may have been deleted."
                return
            }
            _ = try TargetActionExecutor.apply(action, target: fresh, viewModel: targetsViewModel)
            try dbPool.write { db in try TrackEventQueries.setActionStatus(db, id: event.id, status: "applied") }
        } catch { errorMessage = error.localizedDescription }
    }

    func dismissAction(for event: TrackEvent) {
        do {
            try dbPool.write { db in try TrackEventQueries.setActionStatus(db, id: event.id, status: "dismissed") }
        } catch { errorMessage = error.localizedDescription }
    }

    func markRead(_ event: TrackEvent) {
        guard event.isUnread else { return }
        try? dbPool.write { db in try TrackEventQueries.markRead(db, id: event.id) }
    }

    // MARK: - Watch management

    func setCollecting(_ watch: Track, _ on: Bool) {
        try? dbPool.write { db in try TrackQueries.setEnabled(db, id: watch.id, enabled: on) }
    }

    func deleteWatch(_ watch: Track) {
        try? dbPool.write { db in try TrackQueries.delete(db, id: watch.id) }
    }
}

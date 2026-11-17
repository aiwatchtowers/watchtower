import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerInterface

/// Drives the target's "Watch" tab: the watches linked to the target, the
/// origin track it was promoted from (if any), and the merged activity feed
/// from all its watches. Applies a confirmed proposed action to THIS target through the registry.
@MainActor
@Observable
final class TargetWatchesViewModel {
    let target: Target
    private static let log = Logger(subsystem: Constants.bundleID, category: "target-watches")
    private let dbPool: DatabasePool
    /// Every write of this view model, in order (board #670).
    @ObservationIgnored private let writes = SerialWrites()
    /// One pending apply or dismiss per event (board #670).
    let pendingWrites = PendingWrites()
    private let scanCenter: TrackScanCenter
    private let actionPress: TrackActionPress
    private let scanService: TrackScanService
    /// A bound watch's scan goes through the custom-track seam (its recipe);
    /// nil, or an unbound watch, runs `tracks scan` through `scanService`.
    private let trackControls: (any CustomTrackControlling)?
    /// Where the watch and event writes go (nil: they fail with the daemon's sentence).
    private let tower: (any TowerSending)?

    var watches: [Track] = []
    var originTrack: Track?
    var events: [TrackEvent] = []
    var errorMessage: String?

    private var watchesTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?

    init(target: Target,
         dbManager: DatabaseManager,
         scanService: TrackScanService,
         actionRunner: any CLIRunnerProtocol,
         scanCenter: TrackScanCenter,
         trackControls: (any CustomTrackControlling)? = nil,
         tower: (any TowerSending)? = nil) {
        self.target = target
        self.tower = tower
        self.dbPool = dbManager.dbPool
        self.scanService = scanService
        self.trackControls = trackControls
        self.actionPress = TrackActionPress(runner: actionRunner)
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

    /// Scans one watch over the given range (nil = since the last check,
    /// `WatchTrackControls.allHistory` = all history), tracked in the shared
    /// center so the indicator survives navigation. A bound watch gets the
    /// epoch as its Scan from for all history; an unbound one keeps the
    /// legacy flagless `tracks scan`.
    func scanWatch(_ watch: Track, since: Date?, label: String) async {
        scanCenter.begin(watch.id)
        var note: String?
        defer { scanCenter.finish(watch.id, note: note) }
        do {
            if watch.automationID != nil, let trackControls {
                try await trackControls.scan(watch, from: since)
                note = "\(watch.text): \(WatchTrackControls.nextSyncNote.lowercased())."
                return
            }
            let legacySince = since == WatchTrackControls.allHistory ? nil : since
            let iso = legacySince.map { Self.isoFormatter.string(from: $0) }
            let created = try await scanService.run(trackID: watch.id, since: iso)
            note = created.isEmpty
                ? "\(watch.text): no new activity (\(label))."
                : "\(watch.text): \(created.count) new update(s)."
            // The scan ran in a separate CLI process, so the write happened on a
            // different SQLite connection than this one's ValueObservation is
            // tracking — that observation only reacts to same-process writes and
            // will not see the new rows. Refetch explicitly so the feed reflects
            // what the CLI just wrote.
            refreshEvents()
        } catch {
            note = "\(watch.text): scan failed — \(error.localizedDescription)"
            errorMessage = error.localizedDescription
        }
    }

    /// One-shot refetch of the merged activity feed, used after a CLI scan
    /// subprocess completes (see `scanWatch`) since ValueObservation cannot see
    /// writes made by another process.
    private func refreshEvents() {
        if let rows = try? dbPool.read({ db in try TrackEventQueries.fetchForTarget(db, targetID: target.id) }) {
            events = rows
        }
    }

    /// Scans every enabled watch of the target (concurrently is unnecessary —
    /// each is a slow subprocess; run them in sequence to keep it simple).
    func scanAll() async {
        // Once for the batch: a later watch's success must not wipe an
        // earlier watch's failure.
        errorMessage = nil
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

    /// One apply or dismiss per event at a time (board #670): a second
    /// press while the first waits would apply the action twice.
    func applyAction(for event: TrackEvent) async {
        await pendingWrites.run(event.id) { await applyNow(event) }
    }

    func dismissAction(for event: TrackEvent) async {
        await pendingWrites.run(event.id) { await dismissNow(event) }
    }

    private func applyNow(_ event: TrackEvent) async {
        guard event.decodedAction != nil else { return }
        errorMessage = nil
        do {
            try await actionPress.press(eventID: event.id)
        } catch {
            errorMessage = "Failed to apply: \(error.localizedDescription)"
        }
        // The CLI wrote on its own connection: the observations never see it,
        // and a refused press may mean the event or watch is gone.
        refreshEvents()
        refreshWatches()
    }

    /// A failed read keeps the rows shown and is logged.
    private func refreshWatches() {
        do {
            watches = try dbPool.read { db in try TrackQueries.fetchByLinkedTarget(db, targetID: target.id) }
        } catch {
            Self.log.error("reading target \(self.target.id)'s watches: \(error.localizedDescription, privacy: .public)")
        }
    }

    // The watch and event writes are `tracks.*` tower commands (#1170 Task
    // 12): Go writes them, in this view model's chain, and the tab re-reads
    // after the answer — the observations never see another process's write.

    private func dismissNow(_ event: TrackEvent) async {
        errorMessage = nil
        do {
            let id = Int64(event.id)
            let _: ActResult = try await send(.tracksEventStatus) {
                TrackEventStatusRequest(requestID: $0, eventID: id, status: "dismissed")
            }
        } catch { errorMessage = "Failed to dismiss: \(error.localizedDescription)" }
        refreshEvents()
    }

    /// Opening an unread event marks it read; a failure is logged, never shown.
    func markRead(_ event: TrackEvent) async {
        guard event.isUnread else { return }
        let (track, id) = (Int64(event.trackId), Int64(event.id))
        do {
            let _: ActResult = try await send(.tracksEventsRead) {
                TrackEventsReadRequest(requestID: $0, trackID: track, eventID: id)
            }
            refreshEvents()
        } catch {
            Self.log.error("marking event \(id) read: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Watch management

    func setCollecting(_ watch: Track, _ on: Bool) async {
        errorMessage = nil
        do {
            let id = Int64(watch.id)
            let _: ActResult = try await send(.tracksEnabled) { TrackEnabledRequest(requestID: $0, id: id, enabled: on) }
        } catch {
            errorMessage = "Failed to update the watch: \(error.localizedDescription)"
        }
        refreshWatches()
    }

    func deleteWatch(_ watch: Track) async {
        let id = Int64(watch.id)
        do {
            let _: ActResult = try await send(.tracksDelete) { ScreenIDRequest(requestID: $0, id: id) }
        } catch {
            errorMessage = "Failed to delete the watch: \(error.localizedDescription)"
        }
        refreshWatches()
        refreshEvents()
    }

    /// One write in this view model's chain (board #670), through the tower.
    private func send<Resp: Decodable & Sendable, Params: Encodable & Sendable>(
        _ command: TowerCommand, _ params: @escaping (String) -> Params
    ) async throws -> Resp {
        guard let tower else { throw TowerWriteError(TowerText.daemonDown) }
        return try await writes.runThrowing { try await tower.perform(command, params) }
    }
}

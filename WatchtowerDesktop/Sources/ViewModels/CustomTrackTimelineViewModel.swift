import Foundation
import GRDB
import WatchtowerCore

/// Drives the Activity timeline on a CUSTOM track's detail view. Observes
/// `track_events` for the track and, when the track is linked to a target,
/// applies a confirmed proposed action through the registry
/// (`TrackActionPress`: `actions propose --approve`, Go writes the target).
///
/// Ported from the removed `ObserverTimelineViewModel`. A custom track carries a
/// single watch instruction (not N observers), so the observer-management CRUD
/// is gone; the instruction is edited via the compose sheet instead.
@MainActor
@Observable
final class CustomTrackTimelineViewModel {
    let track: Track
    private let dbPool: DatabasePool
    /// Every write of this view model, in order (board #670).
    @ObservationIgnored private let writes = SerialWrites()
    /// One pending apply or dismiss per event (board #670).
    let pendingWrites = PendingWrites()
    private let actionPress: TrackActionPress
    /// Every scan goes through the card's seam (C3 drives the track's watch
    /// recipe there).
    private let controls: any CustomTrackControlling
    /// Shared registry so the "scanning" indicator survives navigation away
    /// from this detail (the list/sidebar read it too).
    private let scanCenter: TrackScanCenter

    var events: [TrackEvent] = []
    /// Watermark of the last scan (ISO8601, "" = never), kept fresh across scans
    /// so the "Last scanned" line reflects what the track has already collected.
    var lastRunAt: String
    var isRefreshing = false
    /// Non-nil while a history backfill runs — drives the visible "Scanning…"
    /// banner so the long (multi-minute) operation is unmistakably in progress.
    var scanStatus: String?
    var errorMessage: String?
    /// Transient result note shown after a scan finishes, so an empty result
    /// reads as "ran, found nothing" rather than "nothing happened".
    var lastScanNote: String?

    /// True when a confirmed proposed action can be applied: the track must be
    /// linked to a target. Standalone tracks hide the Apply button (the scan
    /// prompt already suppresses proposed actions for them).
    var canApplyActions: Bool { track.linkedTargetID != nil }

    private var observationTask: Task<Void, Never>?

    init(track: Track,
         dbManager: DatabaseManager,
         actionRunner: any CLIRunnerProtocol,
         controls: any CustomTrackControlling,
         scanCenter: TrackScanCenter) {
        self.track = track
        self.dbPool = dbManager.dbPool
        self.controls = controls
        self.actionPress = TrackActionPress(runner: actionRunner)
        self.scanCenter = scanCenter
        self.lastRunAt = track.lastRunAt
    }

    /// True while a scan for THIS track is running — whether kicked off here or
    /// still in flight from a previous visit (read from the shared center), so
    /// returning to the detail mid-scan still shows progress.
    var isScanRunning: Bool { isRefreshing || scanCenter.isRunning(track.id) }

    /// Re-reads the persisted watermark after a scan so "Last scanned" updates
    /// without waiting for the detail view to be reopened with a fresh snapshot.
    private func refreshLastRunAt() {
        if let ts = try? dbPool.read({ db in try TrackQueries.fetchLastRunAt(db, id: track.id) }) {
            lastRunAt = ts
        }
    }

    /// One-shot refetch of the timeline, used after a CLI scan subprocess
    /// completes (see `scanSinceLast`/`scanHistory`). The scan writes on a
    /// separate SQLite connection from another process, so the ValueObservation
    /// below — which only reacts to same-process writes — never sees those rows;
    /// this refetch is what makes them show up.
    private func refreshEvents() {
        if let rows = try? dbPool.read({ db in try TrackEventQueries.fetchEvents(db, trackId: track.id) }) {
            events = rows
        }
    }

    func start() {
        let id = track.id
        let dbPool = self.dbPool
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            let observation = ValueObservation.tracking { db -> [TrackEvent] in
                try TrackEventQueries.fetchEvents(db, trackId: id)
            }
            do {
                for try await events in observation.values(in: dbPool) {
                    guard let self else { return }
                    self.events = events
                }
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    /// Incremental scan: reads activity strictly after the watermark and dedups,
    /// so it builds on what the track already collected. Cheap; the right choice
    /// for "keep me current". For an initial fill use `scanHistory`.
    func scanSinceLast() async {
        scanCenter.begin(track.id)
        isRefreshing = true
        errorMessage = nil
        lastScanNote = nil
        defer { isRefreshing = false; scanCenter.finish(track.id, note: lastScanNote ?? errorMessage) }
        do {
            // The CLI subprocess writes any new rows on its own connection, so
            // the ValueObservation above (same-process only) will not see them —
            // refreshEvents() below does the explicit refetch.
            let known = Set(events.map(\.id))
            try await controls.scan(track, from: nil)
            refreshLastRunAt()
            refreshEvents()
            let found = events.filter { !known.contains($0.id) }.count
            lastScanNote = found == 0
                ? "Scan complete — no new activity since the last check. Pick a wider range to backfill older activity."
                : "Found \(found) new update\(found == 1 ? "" : "s")."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Backfills the timeline by scanning history from `since` (nil = all history)
    /// up to now, deduping against existing events, through the card's seam.
    /// `label` describes the range for the in-progress banner. The scan runs
    /// several AI calls and can take a few minutes, so `scanStatus` stays set
    /// for the whole duration. The new events are the ones the refetch adds.
    func scanHistory(since: Date?, label: String) async {
        scanCenter.begin(track.id)
        isRefreshing = true
        scanStatus = "Scanning \(label)… this can take a few minutes"
        errorMessage = nil
        lastScanNote = nil
        defer { isRefreshing = false; scanStatus = nil; scanCenter.finish(track.id, note: lastScanNote ?? errorMessage) }
        let known = Set(events.map(\.id))
        do {
            try await controls.scan(track, from: since ?? Date(timeIntervalSince1970: 0))
            refreshLastRunAt()
            refreshEvents()
            let found = events.filter { !known.contains($0.id) }.count
            lastScanNote = found == 0
                ? "History scan complete — no matching activity found for \(label)."
                : "History scan found \(found) update\(found == 1 ? "" : "s")."
        } catch {
            errorMessage = "History scan failed: \(error.localizedDescription)"
        }
    }

    /// Human "Last scanned" line for the header: relative age of the watermark.
    var lastScannedText: String { Self.lastScannedText(lastRunAt: lastRunAt) }

    /// The same line for any track's `last_run_at` (the Automations → Tracks rows).
    static func lastScannedText(lastRunAt: String) -> String {
        guard !lastRunAt.isEmpty else { return "Not scanned yet" }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: lastRunAt) else { return "Last scanned: \(lastRunAt)" }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return "Last scanned \(rel.localizedString(for: date, relativeTo: Date()))"
    }

    /// Resolves an external "open the source" link for an event: an explicit
    /// source_ref if present, else a resolved permalink for the underlying entity
    /// (e.g. the Slack link of an inbox-sourced event). Returns nil when none.
    func sourceLink(for event: TrackEvent) -> String? {
        if let first = event.decodedRefs.first, !first.isEmpty { return first }
        return try? dbPool.read { db in
            try TrackEventQueries.sourcePermalink(db, sourceType: event.sourceType, sourceId: event.sourceId)
        }
    }

    /// Applies a confirmed proposed action to the LINKED target through the
    /// registry; Go claims the event, writes the target and sets the event's
    /// action_status. Standalone tracks (no linked target) are a no-op: there
    /// is nothing to mutate, and the scan prompt suppresses proposed actions
    /// for them, so the event is left untouched.
    /// One apply or dismiss per event at a time (board #670): a second
    /// press while the first waits would apply the action twice.
    func applyAction(for event: TrackEvent) async {
        await pendingWrites.run(event.id) { await applyNow(event) }
    }

    func dismissAction(for event: TrackEvent) async {
        await pendingWrites.run(event.id) { await dismissNow(event) }
    }

    private func applyNow(_ event: TrackEvent) async {
        guard track.linkedTargetID != nil, event.decodedAction != nil else { return }
        errorMessage = nil
        do {
            try await actionPress.press(eventID: event.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        // The CLI wrote on its own connection: the observation never sees it.
        refreshEvents()
    }

    private func dismissNow(_ event: TrackEvent) async {
        do {
            try await chained { db in
                try TrackEventQueries.setActionStatus(db, id: event.id, status: "dismissed")
            }
        } catch {
            // The observation never sees another process's delete.
            if error is RowNotFoundError { refreshEvents() }
            errorMessage = error.localizedDescription
        }
    }

    /// Cancels the GRDB observation. Call from the view's onDisappear / before
    /// replacing the VM, since a @MainActor deinit cannot touch the task.
    func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    /// Drafts a custom-track title + watch instruction from a free-text request
    /// via the CLI. When the track is linked to a target, that target is passed
    /// for context. Returns nil and sets `errorMessage` on failure.
    func compose(text: String) async -> TrackDraft? {
        guard let runner = ProcessCLIRunner.makeDefault() else {
            errorMessage = "watchtower CLI not found in PATH"
            return nil
        }
        do {
            return try await TrackComposeService(runner: runner).compose(text: text, targetID: track.linkedTargetID)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// A database write in this view model's chain (board #670): it starts
    /// only once every write asked for before it finished.
    private func chained<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await writes.runThrowing { try await self.dbPool.write(body) }
    }
}

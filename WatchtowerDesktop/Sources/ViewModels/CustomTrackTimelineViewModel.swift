import Foundation
import GRDB

/// Drives the Activity timeline on a CUSTOM track's detail view. Observes
/// `track_events` for the track and, when the track is linked to a target,
/// applies a confirmed proposed action through the shared (static)
/// `TargetActionExecutor` — reusing the same TargetsViewModel the chat path uses.
///
/// Ported from the removed `ObserverTimelineViewModel`. A custom track carries a
/// single watch instruction (not N observers), so the observer-management CRUD
/// is gone; the instruction is edited via the compose sheet instead.
@MainActor
@Observable
final class CustomTrackTimelineViewModel {
    let track: Track
    private let dbPool: DatabasePool
    /// Optional: only present (and only usable) when the track is linked to a
    /// target, so a confirmed proposed action has something to mutate.
    private let targetsViewModel: TargetsViewModel?
    private let scanService: TrackScanService

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
    /// linked to a target AND a TargetsViewModel must be available to mutate it.
    /// Standalone tracks hide the Apply button (the scan prompt already
    /// suppresses proposed actions for them).
    var canApplyActions: Bool { track.linkedTargetID != nil && targetsViewModel != nil }

    private var observationTask: Task<Void, Never>?

    init(track: Track,
         dbManager: DatabaseManager,
         scanService: TrackScanService,
         targetsViewModel: TargetsViewModel? = nil) {
        self.track = track
        self.dbPool = dbManager.dbPool
        self.scanService = scanService
        self.targetsViewModel = targetsViewModel
        self.lastRunAt = track.lastRunAt
    }

    /// Re-reads the persisted watermark after a scan so "Last scanned" updates
    /// without waiting for the detail view to be reopened with a fresh snapshot.
    private func refreshLastRunAt() {
        if let ts = try? dbPool.read({ db in try TrackQueries.fetchLastRunAt(db, id: track.id) }) {
            lastRunAt = ts
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
        isRefreshing = true
        errorMessage = nil
        lastScanNote = nil
        defer { isRefreshing = false }
        do {
            // The CLI wrote any new rows; the ValueObservation stream pushes
            // them. The returned slice is exactly what was created this run.
            let created = try await scanService.run(trackID: track.id)
            refreshLastRunAt()
            lastScanNote = created.isEmpty
                ? "Scan complete — no new activity since the last check. Pick a wider range to backfill older activity."
                : "Found \(created.count) new update\(created.count == 1 ? "" : "s")."
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
        lastScanNote = nil
        defer { isRefreshing = false; scanStatus = nil }
        let iso = Self.isoFormatter.string(from: since ?? Date(timeIntervalSince1970: 0))
        do {
            let created = try await scanService.run(trackID: track.id, since: iso)
            refreshLastRunAt()
            lastScanNote = created.isEmpty
                ? "History scan complete — no matching activity found for \(label)."
                : "History scan found \(created.count) update\(created.count == 1 ? "" : "s")."
        } catch {
            errorMessage = "History scan failed: \(error.localizedDescription)"
        }
    }

    /// Human "Last scanned" line for the header: relative age of the watermark.
    var lastScannedText: String {
        guard !lastRunAt.isEmpty else { return "Not scanned yet" }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: lastRunAt) else { return "Last scanned: \(lastRunAt)" }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return "Last scanned \(rel.localizedString(for: date, relativeTo: Date()))"
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
    func sourceLink(for event: TrackEvent) -> String? {
        if let first = event.decodedRefs.first, !first.isEmpty { return first }
        return try? dbPool.read { db in
            try TrackEventQueries.sourcePermalink(db, sourceType: event.sourceType, sourceId: event.sourceId)
        }
    }

    func markRead(_ event: TrackEvent) {
        guard event.isUnread else { return }
        try? dbPool.write { db in try TrackEventQueries.markRead(db, id: event.id) }
    }

    /// Applies a confirmed proposed action to the LINKED target via the shared
    /// static executor, then records the event's action_status so the button does
    /// not re-fire. Standalone tracks (no linked target) are a no-op: there is
    /// nothing to mutate, and the scan prompt suppresses proposed actions for
    /// them, so the event is left untouched.
    func applyAction(for event: TrackEvent) {
        guard let linkedID = track.linkedTargetID, let targetsViewModel else { return }
        guard let action = event.decodedAction else { return }
        do {
            // Apply against a FRESH copy of the target, not an init-time
            // snapshot: the executor's sub-item/note paths are whole-JSON
            // read-modify-writes, so a stale snapshot would clobber anything
            // applied since this VM was created (lost update). A missing row
            // means the target was deleted — surface that instead of silently
            // marking the event applied with no effect.
            guard let fresh = try dbPool.read({ db in
                try TargetQueries.fetchByID(db, id: linkedID)
            }) else {
                errorMessage = "The linked task no longer exists — it may have been deleted."
                return
            }
            _ = try TargetActionExecutor.apply(action, target: fresh, viewModel: targetsViewModel)
            try dbPool.write { db in
                try TrackEventQueries.setActionStatus(db, id: event.id, status: "applied")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissAction(for event: TrackEvent) {
        do {
            try dbPool.write { db in
                try TrackEventQueries.setActionStatus(db, id: event.id, status: "dismissed")
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
}

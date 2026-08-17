import Foundation
import GRDB
import os
import WatchtowerCore

/// Pushes the product slice (briefings, inbox, targets, …) from the local DB
/// to the cloud transport. Runs a poll loop (not ValueObservation — the Go
/// daemon writes via its own connection, so observation never fires; see
/// InboxViewModel.startPolling), diffing rows against `HubSyncState` hashes
/// so only changed records hit the transport.
final class SlicePublisher: Sendable {
    private let dbPool: DatabasePool
    private let state: HubSyncState
    private let transport: any CloudSyncTransport & Sendable
    private let logger = Logger(subsystem: Constants.bundleID, category: "SlicePublisher")
    private let pollTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    /// Feature Manager satellite state (feature id → effective enabled) —
    /// the one slice kind not backed by `sliceSQL`; the source of truth is
    /// the `features` CLI via FeatureManagerService, not the DB. nil until
    /// the first successful feature load: the kind is then skipped entirely
    /// (no upserts AND no deletions), so a fresh launch can never wipe the
    /// phone's last known state before the CLI has answered once.
    private let featureStates = OSAllocatedUnfairLock<[String: Bool]?>(initialState: nil)
    /// The current inter-cycle sleep (nudge cancels it) + a flag for a nudge
    /// that lands while a cycle is already running (the loop then re-runs
    /// immediately instead of sleeping on a stale snapshot).
    private let sleepTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private let nudged = OSAllocatedUnfairLock(initialState: false)

    /// CloudKit's per-record cap is 1 MB. The 100 KB headroom covers system
    /// fields, `kind`/`modifiedAt`/`notifyLevel` and record-name overhead, so
    /// the check runs against the ENCODED row payload alone.
    static let maxPayloadBytes = 900_000

    /// recordName → payload hash of the last oversized payload warned about.
    /// Throttles the oversized warning: an unchanged stuck row warns once per
    /// publisher lifetime, a CHANGED oversized payload warns again.
    private let oversizedWarned = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    /// Count of oversized warnings actually emitted — observability for tests
    /// and debugging of the throttle.
    let oversizedWarningCount = OSAllocatedUnfairLock<Int>(initialState: 0)

    init(dbPool: DatabasePool, state: HubSyncState, transport: any CloudSyncTransport & Sendable) {
        self.dbPool = dbPool
        self.state = state
        self.transport = transport
    }

    /// The v1 slice window per kind — single source of truth for what syncs
    /// FROM THE DB. Exactly one kind is not here: `.featureState` publishes
    /// from the in-memory `featureStates` snapshot (see `updateFeatureStates`),
    /// because feature toggles live in the Go config behind the `features`
    /// CLI, not in a table.
    /// Column names verified against internal/db/schema.sql:
    /// - inbox_items has no 'archived' status; archived-ness is `archived_at`.
    /// - targets' terminal state is 'dismissed' (no 'archived' in its CHECK).
    /// - tracks has `dismissed_at` ('' = active), not a `dismissed` flag.
    /// - calendar_events.start_time is ISO8601 with 'T'/'Z'; wrap in datetime()
    ///   so comparison against datetime('now', …) output is well-defined.
    /// - meeting_transcripts and the three account tables are published as
    ///   PROJECTIONS rather than SELECT * — see the notes on their entries.
    static let sliceSQL: [SliceKind: String] = [
        .briefing: "SELECT * FROM briefings ORDER BY id DESC LIMIT 30",
        .inboxItem: "SELECT * FROM inbox_items WHERE archived_at IS NULL ORDER BY id DESC LIMIT 200",
        .target: "SELECT * FROM targets WHERE status != 'dismissed' ORDER BY id DESC LIMIT 300",
        .track: "SELECT * FROM tracks WHERE dismissed_at = '' ORDER BY id DESC LIMIT 200",
        // `channel_name` is resolved here (the meeting_transcript slice's
        // event_title precedent): the phone has no channels table, and the
        // list rows need "#launch", not "C042". NULL for cross-channel
        // (daily/weekly) digests and channels the sync never stored.
        .digest: """
            SELECT d.*, (SELECT name FROM channels WHERE id = d.channel_id) AS channel_name
            FROM digests d ORDER BY d.id DESC LIMIT 50
            """,
        .digestTopic: """
            SELECT * FROM digest_topics
            WHERE digest_id IN (SELECT id FROM digests ORDER BY id DESC LIMIT 50)
            """,
        .calendarEvent: """
            SELECT * FROM calendar_events
            WHERE datetime(start_time) >= datetime('now', '-1 day')
              AND datetime(start_time) <= datetime('now', '+14 days')
            """,
        .personCard: "SELECT * FROM people_cards ORDER BY id DESC LIMIT 100",
        // Open situations only — done/dismissed/snoozed/converted leave the
        // desktop dashboard feed, so their records fall out of the slice and
        // the diff deletes them from the phone. `signal_ids` joins in the
        // member inbox-item ids so the phone renders member signals from its
        // own inbox slice without syncing the situation_signals table.
        .situation: """
            SELECT situations.*,
                   (SELECT json_group_array(inbox_item_id)
                      FROM situation_signals
                     WHERE situation_id = situations.id) AS signal_ids
            FROM situations
            WHERE status = 'open'
            ORDER BY id DESC LIMIT 100
            """,
        // The ONE slice that is a projection instead of SELECT * — the row
        // holds columns that are either unbounded or meaningless on the phone:
        // transcript_text (tens of KB per hour of meeting), segments_json
        // (per-utterance timings, larger still) and audio_path (a path on THIS
        // Mac). `snippet` is the same 200-char projection the desktop's own
        // recordings list takes for the same perf reason
        // (MeetingTranscriptQueries.fetchRecordingList); full text stays a
        // desktop-only read.
        //
        // Two columns are resolved here so the phone never has to:
        // - recap_json: the desktop's rule (RecordingDetailView.load) is that
        //   the linked event's meeting_recaps row wins and the recording's own
        //   summary_json is the fallback — that IS what COALESCE does, and for
        //   an ad-hoc recording (event_id NULL) the join never matches, so the
        //   fallback applies.
        // - speakers: the cluster ROSTER only. speakers_json holds 256-float
        //   voice embeddings per speaker (~3 KB each) that no phone consumer
        //   can use, so the labels are extracted and the biometrics stay here.
        //
        // Deletion is a hard DELETE (MeetingTranscriptQueries.delete), so there
        // is no soft-delete filter: a deleted recording simply falls out of the
        // window and the diff removes it from the phone.
        .meetingTranscript: """
            SELECT t.id, t.event_id, e.title AS event_title,
                   t.title, t.duration_sec, t.lang_stats, t.notes_md,
                   t.chapters_json, t.created_at, t.updated_at,
                   substr(t.transcript_text, 1, 200) AS snippet,
                   COALESCE(r.recap_json, t.summary_json) AS recap_json,
                   (SELECT json_group_array(json_extract(value, '$.speaker'))
                      FROM json_each(CASE WHEN json_valid(t.speakers_json)
                                          THEN t.speakers_json ELSE '[]' END)) AS speakers
            FROM meeting_transcripts t
            LEFT JOIN calendar_events e ON e.id = t.event_id
            LEFT JOIN meeting_recaps r ON r.event_id = t.event_id
            ORDER BY t.created_at DESC, t.id DESC
            LIMIT 50
            """,
        // Today's plan only — the phone's Today screen is the only consumer,
        // and yesterday's plan falling out of the window is what deletes it
        // from the phone. `date('now','localtime')` matches the desktop's own
        // `DayPlanQueries.todayDateString()` (local zone on both sides), so a
        // plan generated late in the evening is not "tomorrow's" to one and
        // "today's" to the other.
        .dayPlan: """
            SELECT * FROM day_plans
            WHERE plan_date = date('now','localtime')
            ORDER BY id DESC LIMIT 1
            """,
        .dayPlanItem: """
            SELECT * FROM day_plan_items
            WHERE day_plan_id IN (
                SELECT id FROM day_plans
                WHERE plan_date = date('now','localtime')
                ORDER BY id DESC LIMIT 1
            )
            """,
        // Same window shape as the digest slice. SELECT * on purpose: the
        // only content column is topics_json, which IS the digest body — a
        // stream digest tops out at a few KB of topic candidates, so there
        // is no transcript_text-class column to project away.
        .streamDigest: "SELECT * FROM stream_digests ORDER BY id DESC LIMIT 50",
        // Connected-accounts status (read-only on the phone by owner decision,
        // 2026-08-17). PROJECTIONS, never SELECT * — the account tables also
        // carry sync watermarks (search_last_date, gmail_last_internal_date,
        // memory_*_extracted_ts, ideas_* floors) and credential-adjacent
        // state (google_accounts.client_id) that must never reach the wire.
        // The exact column sets are frozen by SlicePublisherTests and the
        // Kit's ConnectedAccount fixtures.
        //
        // Slack/Jira `status = 'removed'` rows are tombstones (`slack remove`/
        // `jira remove` keep the row so historical data stays attributable —
        // see JiraAccountQueries.fetchAll): they leave the window, so the
        // diff deletes the account from the phone. google_accounts has no
        // 'removed' status — removal deletes the row, same effect.
        .slackAccount: """
            SELECT id, team_name, team_domain, label, status, error, enabled
            FROM slack_accounts
            WHERE status != 'removed'
            ORDER BY id ASC
            """,
        .googleAccount: """
            SELECT id, email, label, status, error, calendar_enabled, gmail_enabled
            FROM google_accounts
            ORDER BY id ASC
            """,
        .jiraAccount: """
            SELECT id, site_name, site_url, label, status, error, enabled
            FROM jira_accounts
            WHERE status != 'removed'
            ORDER BY id ASC
            """
    ]

    // MARK: - Publishing

    /// One full push cycle over all slice kinds. Returns what happened;
    /// skipped (un-encodable) records are also logged once per cycle.
    /// Oversized records (payload above `maxPayloadBytes`) are skipped WITHOUT
    /// recording their hash — the diff re-offers the row every cycle, so a
    /// later smaller version publishes normally. Their warning is throttled
    /// per (recordName, payload hash) and they stay out of the end-of-cycle
    /// un-encodable line, so a stuck row does not spam the log.
    @discardableResult
    func publishOnce() async throws -> (pushed: Int, deleted: Int, skipped: [String]) {
        var pushed = 0
        var deleted = 0
        var skipped: [String] = []
        var diffSkipped: [String] = []
        let now = Date()
        let startGen = try state.generation()

        for kind in SliceKind.allCases {
            let rows: [(id: String, row: Row)]
            if kind == .featureState {
                guard let states = featureStates.withLock({ $0 }) else { continue }
                rows = Self.featureStateRows(states)
            } else {
                guard let sql = Self.sliceSQL[kind] else { continue }
                let fetched = try fetchSliceRows(sql: sql)
                rows = fetched.map { (id: Self.rowID($0), row: $0) }
            }
            let result = SliceDiff.compute(
                kind: kind,
                rows: rows,
                knownHashes: try state.hashes(forKind: kind),
                now: now
            )

            var saveable: [SliceRecord] = []
            for record in result.upserts {
                if Self.isOversized(record.payload) {
                    skipped.append(record.recordName)
                    warnOversizedIfNeeded(record)
                } else {
                    saveable.append(record)
                }
            }

            if !saveable.isEmpty {
                try await transport.save(saveable.map { CloudRecordFactory.record(for: $0) })
                // Guard: abort if a mid-cycle account reset wiped the state.
                // The next cycle will re-diff against empty hashes and re-push everything.
                // Residual race (accepted, Plan 3 final review): a reset landing in the
                // few statements between this check and the setHash writes still slips through.
                guard try state.generation() == startGen else {
                    logger.warning("publishOnce: generation changed mid-cycle — aborting to avoid recording stale hashes")
                    return (pushed, deleted, skipped)
                }
                for record in saveable {
                    try state.setHash(SliceDiff.hashHex(record.payload), for: record.recordName)
                    // A published record's throttle entry is stale: if the row
                    // ever grows oversized again, that deserves a fresh warning.
                    oversizedWarned.withLock { $0.removeValue(forKey: record.recordName) }
                }
                pushed += saveable.count
            }
            if !result.deletions.isEmpty {
                try await transport.delete(recordNames: result.deletions, in: .data)
                guard try state.generation() == startGen else {
                    logger.warning("publishOnce: generation changed mid-cycle — aborting to avoid recording stale hashes")
                    return (pushed, deleted, skipped)
                }
                try state.removeHashes(result.deletions)
                deleted += result.deletions.count
            }
            skipped.append(contentsOf: result.skipped)
            diffSkipped.append(contentsOf: result.skipped)
        }

        // Only diff-level skips (encoder throw / invalid id) — oversized rows
        // have their own throttled warning and would re-spam this line every
        // cycle while stuck.
        if !diffSkipped.isEmpty {
            logger.warning("skipped \(diffSkipped.count) un-encodable slice records: \(diffSkipped.joined(separator: ", "), privacy: .public)")
        }
        return (pushed, deleted, skipped)
    }

    /// True when `payload` exceeds the publishable budget. `==` is fine:
    /// exactly `maxPayloadBytes` still fits within the headroom.
    static func isOversized(_ payload: Data) -> Bool {
        payload.count > maxPayloadBytes
    }

    /// Warns about an oversized record, throttled per (recordName, payload
    /// hash): the same stuck payload warns once, a changed one warns again.
    private func warnOversizedIfNeeded(_ record: SliceRecord) {
        let hash = SliceDiff.hashHex(record.payload)
        let firstSighting = oversizedWarned.withLock { warned in
            guard warned[record.recordName] != hash else { return false }
            warned[record.recordName] = hash
            return true
        }
        guard firstSighting else { return }
        oversizedWarningCount.withLock { $0 += 1 }
        logger.warning("""
            oversized slice record skipped: \(record.recordName, privacy: .public) \
            payload \(record.payload.count) bytes exceeds \(Self.maxPayloadBytes) — \
            not published, will retry when the row shrinks
            """)
    }

    /// Synchronous on purpose: GRDB's async `read` requires `T: Sendable`,
    /// and `Row` is explicitly non-Sendable in GRDB 7, so `[Row]` can never
    /// go through the async overload — local toolchains masked this by
    /// accepting `await` on the sync overload, CI's does not. In a non-async
    /// function only the sync overload exists; nothing is left to resolve.
    private func fetchSliceRows(sql: String) throws -> [Row] {
        try dbPool.read { db in
            try Row.fetchAll(db, sql: sql)
        }
    }

    // MARK: - Feature state

    /// Replaces the feature-state snapshot and nudges the poll loop so the
    /// change publishes now, not up to a full interval later ("published on
    /// change"; the diff still dedups an unchanged map). With no loop
    /// running (hub off/unavailable) the snapshot just waits for start().
    func updateFeatureStates(_ states: [String: Bool]) {
        featureStates.withLock { $0 = states }
        nudged.withLock { $0 = true }
        sleepTask.withLock { $0?.cancel() }
    }

    /// Sorted for a deterministic publish order; the payload is the frozen
    /// `{id, enabled}` row-dict (SQLite booleans are integers on the wire,
    /// like every SQL-backed slice).
    private static func featureStateRows(_ states: [String: Bool]) -> [(id: String, row: Row)] {
        states.sorted { $0.key < $1.key }.map { id, enabled in
            (id: id, row: Row(["id": id, "enabled": enabled]))
        }
    }

    // MARK: - Poll loop

    func start(interval: Duration = .seconds(60)) {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.nudged.withLock { $0 = false }
                do {
                    _ = try await self.publishOnce()
                } catch {
                    self.logger.error("publish cycle failed: \(error.localizedDescription, privacy: .public)")
                }
                // A nudge that landed mid-cycle re-runs immediately —
                // publishOnce may have already diffed feature_state against
                // the pre-nudge snapshot. Otherwise sleep on a cancellable
                // sub-task so a nudge wakes the loop without killing it.
                if self.nudged.withLock({ $0 }) { continue }
                let sleep = Task { _ = try? await Task.sleep(for: interval) }
                self.sleepTask.withLock { $0 = sleep }
                await sleep.value
            }
        }
        pollTask.withLock { current in
            current?.cancel()
            current = task
        }
    }

    func stop() {
        pollTask.withLock { current in
            current?.cancel()
            current = nil
        }
        // The loop awaits the sleep sub-task, which does not observe the
        // parent's cancellation — cancel it too so stop() stays prompt
        // (matching the pre-nudge `Task.sleep` behavior).
        sleepTask.withLock { current in
            current?.cancel()
            current = nil
        }
    }

    // MARK: - Helpers

    /// Slice ids are INTEGER for most tables but TEXT for calendar_events,
    /// so read the raw storage instead of forcing an Int64 conversion
    /// (which would fatalError on TEXT primary keys in GRDB).
    private static func rowID(_ row: Row) -> String {
        let dbValue: DatabaseValue = row["id"] ?? .null
        switch dbValue.storage {
        case .int64(let value):
            return String(value)
        case .string(let value):
            return value
        default:
            return "0"
        }
    }
}

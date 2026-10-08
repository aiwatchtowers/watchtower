import Foundation
import GRDB
import WatchtowerSync

/// The hub's sidecar database (`hubstate.db`, mobile POC spec §3): what was
/// last pushed per DataZone record (`slice_state`), small hub values
/// (`hub_meta`), the exactly-once ledger of relay records
/// (`relay_processed`, spec §5.2 rule 1), the asks already alerted
/// (`alerted_asks`, spec §4.7), where each phone answer's line went
/// (`ask_answer_deliveries`, spec §5.2/§6.2) and the phone recordings the
/// hub ingested (`phone_recordings`, spec §6.4/§4.12).
/// Mirrors the TransportStore GRDB pattern: DatabaseQueue + `CREATE TABLE IF NOT EXISTS`.
final class HubSyncState: Sendable {
    /// Where one relay record stands in the exactly-once ledger.
    enum RelayPhase: String {
        /// Committed before a non-idempotent kind writes; still `begun` at
        /// a later pass means the hub stopped mid-apply.
        case begun
        /// Handled and echoed (or skipped for good); never handled again.
        case done
    }

    static let hubIDKey = "hub_id"
    private static let generationKey = "sync_generation"

    private let queue: DatabaseQueue
    /// One relay pass at a time over this ledger, whichever processor runs
    /// it (a rebuilt hub shares the sidecar with the one it replaces).
    let relayGate = RelayPassGate()

    init(path: String) throws {
        // A second handle on the file (a relaunch whose old instance is
        // still closing, a duplicate app instance) waits for the lock
        // instead of failing at once with SQLITE_BUSY.
        var config = Configuration()
        config.busyMode = .timeout(5)
        queue = try DatabaseQueue(path: path, configuration: config)
        try createSchema()
    }

    private init(queue: DatabaseQueue) throws {
        self.queue = queue
        try createSchema()
    }

    static func inMemory() throws -> HubSyncState {
        try HubSyncState(queue: DatabaseQueue())
    }

    private func createSchema() throws {
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS slice_state (
                    record_name TEXT PRIMARY KEY,
                    payload_hash TEXT NOT NULL,
                    pushed_at REAL NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS hub_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS alerted_asks (
                    ask_id INTEGER PRIMARY KEY,
                    at REAL NOT NULL,
                    generation INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS relay_processed (
                    record_name TEXT PRIMARY KEY,
                    phase TEXT NOT NULL CHECK (phase IN ('begun', 'done')),
                    outcome TEXT,
                    updated_at REAL NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS ask_answer_deliveries (
                    record_name TEXT PRIMARY KEY,
                    delivery TEXT NOT NULL,
                    at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS phone_recordings (
                    upload_id TEXT PRIMARY KEY,
                    audio_path TEXT NOT NULL,
                    transcript_id INTEGER,
                    status TEXT NOT NULL,
                    percent INTEGER,
                    error TEXT,
                    updated_at REAL NOT NULL
                );
                """)
        }
    }

    // MARK: - Hash queries

    /// Returns a recordName → payloadHash map for all records of the given kind.
    /// Filtered by `record_name LIKE '<kind.rawValue>-%'`.
    func hashes(forKind kind: SliceKind) throws -> [String: String] {
        try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT record_name, payload_hash FROM slice_state WHERE record_name LIKE ? ESCAPE '\\'",
                arguments: [kind.rawValue.replacingOccurrences(of: "_", with: "\\_") + "-%"]
            )
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["record_name"] as String, $0["payload_hash"] as String) })
        }
    }

    func setHash(_ hash: String, for recordName: String) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO slice_state (record_name, payload_hash, pushed_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(record_name) DO UPDATE SET
                        payload_hash = excluded.payload_hash,
                        pushed_at = excluded.pushed_at
                    """,
                arguments: [recordName, hash, Date().timeIntervalSince1970]
            )
        }
    }

    func removeHashes(_ recordNames: [String]) throws {
        guard !recordNames.isEmpty else { return }
        try queue.write { db in
            for name in recordNames {
                try db.execute(sql: "DELETE FROM slice_state WHERE record_name = ?", arguments: [name])
            }
        }
    }

    // MARK: - Hub meta (relay change token, hub id, …)

    func metaValue(forKey key: String) throws -> String? {
        try queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM hub_meta WHERE key = ?", arguments: [key])
        }
    }

    func setMetaValue(_ value: String, forKey key: String) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO hub_meta (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [key, value]
            )
        }
    }

    /// This install's hub id (spec §4.1), created on first use and kept for
    /// good: an account reset does not change which Mac this is.
    func ensureHubID() throws -> String {
        try ensureMetaValue(forKey: Self.hubIDKey) { UUID().uuidString.lowercased() }
    }

    /// The value under `key`, or `make()` stored there when the key is new.
    /// One write transaction, so two callers never store two values.
    func ensureMetaValue(forKey key: String, make: () -> String) throws -> String {
        try queue.write { db in
            if let existing = try String.fetchOne(
                db, sql: "SELECT value FROM hub_meta WHERE key = ?", arguments: [key]
            ) {
                return existing
            }
            let fresh = make()
            try db.execute(sql: "INSERT INTO hub_meta (key, value) VALUES (?, ?)", arguments: [key, fresh])
            return fresh
        }
    }

    // MARK: - Relay exactly-once ledger (spec §5.2 rule 1)

    func relayPhase(_ recordName: String) throws -> RelayPhase? {
        try queue.read { db in
            let raw = try String.fetchOne(
                db,
                sql: "SELECT phase FROM relay_processed WHERE record_name = ?",
                arguments: [recordName]
            )
            return raw.flatMap(RelayPhase.init(rawValue:))
        }
    }

    /// The atomic `begun` claim of a non-idempotent kind, committed BEFORE
    /// it touches the main DB or a PTY: true only for the one caller whose
    /// insert created the row, so two passes can never both apply it.
    func claimRelay(_ recordName: String, at date: Date) throws -> Bool {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO relay_processed (record_name, phase, outcome, updated_at)
                    VALUES (?, 'begun', NULL, ?)
                    ON CONFLICT(record_name) DO NOTHING
                    """,
                arguments: [recordName, date.timeIntervalSince1970]
            )
            return db.changesCount > 0
        }
    }

    /// The `begun` claim of a phone recording upload (spec §5.3): like
    /// `claimRelay`, and it also takes over a record whose last attempt was
    /// echoed `failed`. The phone's Retry re-sends the same record name, and
    /// a failed ingest wrote nothing, so the retry is ingested; a `received`
    /// record is never claimed again.
    func claimRelayRetryingFailure(_ recordName: String, at date: Date) throws -> Bool {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO relay_processed (record_name, phase, outcome, updated_at)
                    VALUES (?, 'begun', NULL, ?)
                    ON CONFLICT(record_name) DO UPDATE SET
                        phase = 'begun', outcome = NULL, updated_at = excluded.updated_at
                    WHERE relay_processed.phase = 'done' AND relay_processed.outcome LIKE 'failed%'
                    """,
                arguments: [recordName, date.timeIntervalSince1970]
            )
            return db.changesCount > 0
        }
    }

    /// The outcome a `done` record was marked with; nil for an unknown or
    /// `begun` record.
    func relayOutcome(_ recordName: String) throws -> String? {
        try queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT outcome FROM relay_processed WHERE record_name = ?",
                arguments: [recordName]
            )
        }
    }

    /// Marks a record `begun` whatever it held (tests seed an interrupted
    /// apply with it; the hub itself claims through `claimRelay`).
    func markRelayBegun(_ recordName: String, at date: Date) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO relay_processed (record_name, phase, outcome, updated_at)
                    VALUES (?, 'begun', NULL, ?)
                    ON CONFLICT(record_name) DO UPDATE SET phase = 'begun', updated_at = excluded.updated_at
                    """,
                arguments: [recordName, date.timeIntervalSince1970]
            )
        }
    }

    /// `outcome` is the echoed status (and reason, when there is one), for
    /// diagnostics only: a `done` record is skipped whatever it holds.
    func markRelayDone(_ recordName: String, outcome: String, at date: Date) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO relay_processed (record_name, phase, outcome, updated_at)
                    VALUES (?, 'done', ?, ?)
                    ON CONFLICT(record_name) DO UPDATE SET
                        phase = 'done', outcome = excluded.outcome, updated_at = excluded.updated_at
                    """,
                arguments: [recordName, outcome, date.timeIntervalSince1970]
            )
        }
    }

    /// Retention: drops ledger entries last touched before `date`. Safe
    /// because the cutoff lies past the relay max age: a re-delivered record
    /// that old fails the age check (`expired`) and is never applied, and an
    /// already-echoed record is skipped on its echo status first.
    func pruneRelayProcessed(olderThan date: Date) throws {
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM relay_processed WHERE updated_at < ?",
                arguments: [date.timeIntervalSince1970]
            )
            try db.execute(
                sql: "DELETE FROM ask_answer_deliveries WHERE at < ?",
                arguments: [date.timeIntervalSince1970]
            )
        }
    }

    // MARK: - Ask answer deliveries (spec §5.2, §6.2)

    /// Where the line of the answer `recordName` stored went (the wire
    /// `delivery`), written right after the store and before the echo: a
    /// re-run of the same action (its echo's save failed, or the hub
    /// stopped before it) echoes it again instead of storing twice.
    func recordAskAnswerDelivery(_ delivery: String, for recordName: String, at date: Date) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO ask_answer_deliveries (record_name, delivery, at) VALUES (?, ?, ?)
                    ON CONFLICT(record_name) DO UPDATE SET delivery = excluded.delivery, at = excluded.at
                    """,
                arguments: [recordName, delivery, date.timeIntervalSince1970]
            )
        }
    }

    func askAnswerDelivery(for recordName: String) throws -> String? {
        try queue.read { db in
            try String.fetchOne(
                db, sql: "SELECT delivery FROM ask_answer_deliveries WHERE record_name = ?", arguments: [recordName]
            )
        }
    }

    // MARK: - Phone recordings (spec §6.4, §4.12)

    /// One phone upload the hub ingested and where its transcription stands:
    /// the `recording_job` slice's source, and (through `transcript_id`) the
    /// `meeting_transcript` slice's `phone_recording_id`.
    struct PhoneRecordingJob: Equatable, Sendable {
        /// The wire `recording_job.status` values (Kit `RecordingJobStatus`).
        enum Status: String, Sendable {
            case received, queued, transcribing, diarizing, summarizing, done, failed

            var isFinished: Bool { self == .done || self == .failed }
        }

        /// The phone's recording upload id (`RecordingUploadPayload.id`).
        let uploadID: String
        /// The ingested `rec_*.m4a`: the key the transcriber's job callbacks
        /// report under. Never published.
        let audioPath: String
        var status: Status
        /// 0–100 while `transcribing`.
        var percent: Int?
        var transcriptID: Int64?
        var error: String?
        var updatedAt: Date
    }

    func savePhoneRecording(_ job: PhoneRecordingJob) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO phone_recordings (upload_id, audio_path, transcript_id, status, percent, error, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(upload_id) DO UPDATE SET
                        audio_path = excluded.audio_path, transcript_id = excluded.transcript_id,
                        status = excluded.status, percent = excluded.percent, error = excluded.error,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    job.uploadID, job.audioPath, job.transcriptID, job.status.rawValue, job.percent, job.error,
                    job.updatedAt.timeIntervalSince1970
                ]
            )
        }
    }

    /// Every remembered phone recording, newest first. A row whose status
    /// this build does not know reads as `queued`.
    func phoneRecordings() throws -> [PhoneRecordingJob] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT upload_id, audio_path, transcript_id, status, percent, error, updated_at
                FROM phone_recordings ORDER BY updated_at DESC, upload_id
                """)
            return rows.map { row in
                PhoneRecordingJob(
                    uploadID: row["upload_id"],
                    audioPath: row["audio_path"],
                    status: PhoneRecordingJob.Status(rawValue: row["status"] ?? "") ?? .queued,
                    percent: row["percent"],
                    transcriptID: row["transcript_id"],
                    error: row["error"],
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"])
                )
            }
        }
    }

    /// Forgets the phone recordings last updated before `date`.
    func prunePhoneRecordings(olderThan date: Date) throws {
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM phone_recordings WHERE updated_at < ?",
                arguments: [date.timeIntervalSince1970]
            )
        }
    }

    // MARK: - Ask alerts (spec §4.7)

    /// When an ask's `ask_alert` was first written, and in which sync
    /// generation: an alert is published only in the generation that wrote
    /// it, so a new account's zone never gets an alert for an old ask.
    struct AlertedAsk: Equatable, Sendable {
        let at: Date
        let generation: Int
    }

    /// Remembers each of `askIDs` not alerted yet as alerted at `date` in
    /// the current generation (a remembered one keeps its first stamp), and
    /// returns every remembered ask. One write transaction, so two cycles
    /// never alert one ask twice.
    func markAlerted(_ askIDs: [Int64], at date: Date) throws -> [Int64: AlertedAsk] {
        try queue.write { db in
            let raw = try String.fetchOne(
                db, sql: "SELECT value FROM hub_meta WHERE key = ?", arguments: [Self.generationKey]
            )
            let generation = raw.flatMap(Int.init) ?? 0
            for id in askIDs {
                try db.execute(
                    sql: "INSERT INTO alerted_asks (ask_id, at, generation) VALUES (?, ?, ?) ON CONFLICT(ask_id) DO NOTHING",
                    arguments: [id, date.timeIntervalSince1970, generation]
                )
            }
            return try Self.fetchAlerted(db)
        }
    }

    func alertedAsks() throws -> [Int64: AlertedAsk] {
        try queue.read(Self.fetchAlerted)
    }

    /// Forgets the asks alerted before `date` that are not in `keeping` (the
    /// asks still open): a closed ask never reopens, while an open one must
    /// stay remembered, or it would alert a second time.
    func pruneAlertedAsks(olderThan date: Date, keeping: Set<Int64>) throws {
        try queue.write { db in
            let stale = try Int64.fetchAll(
                db, sql: "SELECT ask_id FROM alerted_asks WHERE at < ?", arguments: [date.timeIntervalSince1970]
            )
            for id in stale where !keeping.contains(id) {
                try db.execute(sql: "DELETE FROM alerted_asks WHERE ask_id = ?", arguments: [id])
            }
        }
    }

    private static func fetchAlerted(_ db: Database) throws -> [Int64: AlertedAsk] {
        let rows = try Row.fetchAll(db, sql: "SELECT ask_id, at, generation FROM alerted_asks")
        return Dictionary(uniqueKeysWithValues: rows.map {
            ($0["ask_id"] as Int64, AlertedAsk(at: Date(timeIntervalSince1970: $0["at"]), generation: $0["generation"]))
        })
    }

    // MARK: - Account-change reset

    /// Clears the sync state derived from the CloudKit account so the next
    /// publish/relay cycle starts clean against the new account: slice
    /// hashes, the relay change token and the heartbeat read state (the new
    /// account's DataZone is another zone). The exactly-once ledger is KEPT:
    /// relay record names carry phone-generated UUIDs, so they cannot
    /// collide across accounts, and on a same-Apple-ID sign-out/sign-in the
    /// re-fetched zone still holds actions whose echo never reached the
    /// server — without the ledger they would be applied a second time
    /// (spec §8 I-3, §9). The hygiene stamp, the hub id and `enabled_at`
    /// are kept too, and so are the alerted asks: the new account's zone
    /// must not get an alert for an ask alerted before (spec §4.7).
    /// The generation counter is bumped so an in-flight publish cycle can
    /// detect the reset and abort before recording stale hashes.
    func wipeSyncState() throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM slice_state")
            for key in [RelayProcessor.relayTokenKey] + HubIdentity.heartbeatReadKeys {
                try db.execute(sql: "DELETE FROM hub_meta WHERE key = ?", arguments: [key])
            }
            try db.execute(
                sql: """
                    INSERT INTO hub_meta (key, value)
                    VALUES (?, CAST(COALESCE((SELECT value FROM hub_meta WHERE key = ?), '0') AS INTEGER) + 1)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [Self.generationKey, Self.generationKey]
            )
        }
    }

    /// The sync generation counter: 0 until the first `wipeSyncState()`.
    func generation() throws -> Int {
        let raw = try metaValue(forKey: Self.generationKey)
        return raw.flatMap(Int.init) ?? 0
    }
}

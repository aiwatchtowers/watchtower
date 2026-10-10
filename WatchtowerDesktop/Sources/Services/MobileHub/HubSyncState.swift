import CloudKit
import Foundation
import GRDB
import WatchtowerSync

/// The hub's sidecar database (`hubstate.db`, mobile POC spec §3): what was
/// last pushed per DataZone record (`slice_state`), small hub values
/// (`hub_meta`), the exactly-once ledger of relay records
/// (`relay_processed`, spec §5.2 rule 1), the asks already alerted
/// (`alerted_asks`, spec §4.7), where each phone answer's line went
/// (`ask_answer_deliveries`, spec §5.2/§6.2), the phone recordings the
/// hub ingested (`phone_recordings`, spec §6.4/§4.12), the last capped
/// session reports (`session_reports`, spec §4.8) and the hub-observed
/// session state milestones (`session_milestones`, spec §4.9), and the
/// linking state (spec §2.3): the issued QR codes (`link_codes`), the linked
/// phones (`devices`, spec §10) and the refused link attempts
/// (`link_refusals`, published as `device_grant` with `link_refused`).
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

    /// One IMMEDIATE transaction: two instances opening an old file at once
    /// (a relaunch overlap, a duplicate app) take the write lock in turn
    /// under the busy timeout, so the second sees the upgraded columns
    /// instead of failing the read-to-write upgrade with SQLITE_BUSY.
    private func createSchema() throws {
        try queue.inTransaction(.immediate) { db in
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
                    updated_at REAL NOT NULL DEFAULT 0,
                    echo BLOB,
                    done_seq INTEGER
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
                CREATE TABLE IF NOT EXISTS session_reports (
                    session_id INTEGER PRIMARY KEY,
                    payload BLOB NOT NULL,
                    fetched_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS session_milestones (
                    session_id INTEGER NOT NULL,
                    at REAL NOT NULL,
                    kind TEXT NOT NULL CHECK (kind = 'state'),
                    text TEXT NOT NULL,
                    ref INTEGER
                );
                CREATE INDEX IF NOT EXISTS session_milestones_by_session ON session_milestones (session_id, at);
                """)
            try Self.createLinkTables(db)
            // A sidecar created before the ledger kept echoes and buffer
            // marks gains the columns; its old `done` rows hold neither (no
            // echo: skipped as before; no mark: the pre-mark behaviour).
            let columns = Set(try db.columns(in: "relay_processed").map(\.name))
            for (name, type) in [("echo", "BLOB"), ("done_seq", "INTEGER")] where !columns.contains(name) {
                try db.execute(sql: "ALTER TABLE relay_processed ADD COLUMN \(name) \(type)")
            }
            return .commit
        }
    }

    /// The linking tables (spec §2.3, §10).
    private static func createLinkTables(_ db: Database) throws {
        try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS link_codes (
                    nonce TEXT PRIMARY KEY,
                    issued_at REAL NOT NULL,
                    exp REAL NOT NULL,
                    used_by_device TEXT,
                    used_at REAL
                );
                CREATE TABLE IF NOT EXISTS devices (
                    device_id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    user_record_name TEXT NOT NULL,
                    linked_at REAL NOT NULL,
                    typing_allowed INTEGER NOT NULL DEFAULT 0,
                    start_sessions_allowed INTEGER NOT NULL DEFAULT 1,
                    decided_at REAL
                );
                CREATE TABLE IF NOT EXISTS link_refusals (
                    device_id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    at REAL NOT NULL
                );
                """)
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

    /// Unconditional (no generation check): test seeding only. The publisher
    /// records hashes through `setHashes(_:ifGeneration:)`.
    func setHash(_ hash: String, for recordName: String) throws {
        try queue.write { try Self.upsertHash(hash, for: recordName, $0) }
    }

    /// Records `hashes` (record name → hash) only while the sync generation
    /// is still `generation`, checked in the same transaction, so a reset
    /// cannot land between the check and the writes. False (nothing
    /// written) when a reset bumped it.
    func setHashes(_ hashes: [String: String], ifGeneration generation: Int) throws -> Bool {
        try queue.write { db in
            guard try Self.generation(db) == generation else { return false }
            for (name, hash) in hashes {
                try Self.upsertHash(hash, for: name, db)
            }
            return true
        }
    }

    private static func upsertHash(_ hash: String, for recordName: String, _ db: Database) throws {
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

    func removeHashes(_ recordNames: [String]) throws {
        guard !recordNames.isEmpty else { return }
        try queue.write { try Self.deleteHashes(recordNames, $0) }
    }

    /// `removeHashes` only while the sync generation is still `generation`,
    /// checked in the same transaction. False (nothing removed) when a reset
    /// bumped it.
    func removeHashes(_ recordNames: [String], ifGeneration generation: Int) throws -> Bool {
        try queue.write { db in
            guard try Self.generation(db) == generation else { return false }
            try Self.deleteHashes(recordNames, db)
            return true
        }
    }

    private static func deleteHashes(_ recordNames: [String], _ db: Database) throws {
        for name in recordNames {
            try db.execute(sql: "DELETE FROM slice_state WHERE record_name = ?", arguments: [name])
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

    /// `outcome` is the echoed status (and reason, when there is one): what
    /// a recording upload's retry decides on, diagnostics for an action.
    /// `echo` is the full echoed outcome of an action, re-echoed as is when
    /// the record reads `pending` or `received` again (a lost ack); nil
    /// for a recording upload. `doneSeq` is the relay buffer mark the
    /// marking pass read up to: only a change buffered past it is a phone
    /// save made after this outcome (see `RelayProcessor`).
    func markRelayDone(_ recordName: String, outcome: String, echo: Data? = nil, doneSeq: Int? = nil, at date: Date) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO relay_processed (record_name, phase, outcome, updated_at, echo, done_seq)
                    VALUES (?, 'done', ?, ?, ?, ?)
                    ON CONFLICT(record_name) DO UPDATE SET
                        phase = 'done', outcome = excluded.outcome, updated_at = excluded.updated_at,
                        echo = excluded.echo, done_seq = excluded.done_seq
                    """,
                arguments: [recordName, outcome, date.timeIntervalSince1970, echo, doneSeq]
            )
        }
    }

    /// The relay buffer mark a `done` record was marked at; nil for an
    /// unknown or `begun` record, or a row written before marks were kept.
    func relayDoneSeq(_ recordName: String) throws -> Int? {
        try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT done_seq FROM relay_processed WHERE record_name = ? AND phase = 'done'",
                arguments: [recordName]
            )
        }
    }

    /// The echo a `done` action was marked with; nil for an unknown or
    /// `begun` record, an upload, or a row written before echoes were kept.
    func relayEcho(_ recordName: String) throws -> Data? {
        try queue.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT echo FROM relay_processed WHERE record_name = ? AND phase = 'done'",
                arguments: [recordName]
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

    // MARK: - Session reports (spec §4.8)

    /// One session's last good report, capped and encoded for the wire.
    struct StoredSessionReport: Equatable, Sendable {
        let payload: Data
        let fetchedAt: Date
    }

    /// Stores `payload` as the session's report; whether it differed from
    /// the stored one (an unchanged report keeps its first stamp).
    @discardableResult
    func saveSessionReport(_ payload: Data, sessionID: Int64, at date: Date) throws -> Bool {
        try queue.write { db in
            let current = try Data.fetchOne(
                db, sql: "SELECT payload FROM session_reports WHERE session_id = ?", arguments: [sessionID]
            )
            guard current != payload else { return false }
            try db.execute(
                sql: """
                    INSERT INTO session_reports (session_id, payload, fetched_at) VALUES (?, ?, ?)
                    ON CONFLICT(session_id) DO UPDATE SET payload = excluded.payload, fetched_at = excluded.fetched_at
                    """,
                arguments: [sessionID, payload, date.timeIntervalSince1970]
            )
            return true
        }
    }

    func sessionReports() throws -> [Int64: StoredSessionReport] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT session_id, payload, fetched_at FROM session_reports")
            return Dictionary(uniqueKeysWithValues: rows.map {
                ($0["session_id"] as Int64, StoredSessionReport(payload: $0["payload"], fetchedAt: Date(timeIntervalSince1970: $0["fetched_at"])))
            })
        }
    }

    /// Forgets the reports of every session not in `keeping` (sessions that
    /// left the report window).
    func removeSessionReports(keeping: Set<Int64>) throws {
        try queue.write { db in
            let stored = try Int64.fetchAll(db, sql: "SELECT session_id FROM session_reports")
            for id in stored where !keeping.contains(id) {
                try db.execute(sql: "DELETE FROM session_reports WHERE session_id = ?", arguments: [id])
            }
        }
    }

    // MARK: - Session milestones (spec §4.9)

    /// A hub-observed resolved state transition of a session ("Working",
    /// "Needs approval", …). The table holds `state` milestones only: the
    /// other timeline kinds are read from their own rows, and subagent
    /// events have no source at all (OD-3).
    struct StateMilestone: Equatable, Sendable {
        let sessionID: Int64
        let at: Date
        let text: String
    }

    static let milestonesPerSession = 100
    static let milestoneLifetime: TimeInterval = 14 * 86_400

    /// Records one state milestone, then keeps the session's newest 100.
    func addStateMilestone(_ milestone: StateMilestone) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO session_milestones (session_id, at, kind, text, ref) VALUES (?, ?, 'state', ?, NULL)",
                arguments: [milestone.sessionID, milestone.at.timeIntervalSince1970, milestone.text]
            )
            try Self.trimMilestones(db, sessionID: milestone.sessionID)
        }
    }

    /// Every stored state milestone by session, newest first.
    func stateMilestones() throws -> [Int64: [StateMilestone]] {
        try queue.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT session_id, at, text FROM session_milestones ORDER BY session_id, at DESC, rowid DESC"
            )
            return Dictionary(grouping: rows.map {
                StateMilestone(sessionID: $0["session_id"], at: Date(timeIntervalSince1970: $0["at"]), text: $0["text"])
            }, by: \.sessionID)
        }
    }

    /// Drops the milestones older than `date` (14 days before now) and any
    /// past a session's newest 100.
    func pruneSessionMilestones(olderThan date: Date) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM session_milestones WHERE at < ?", arguments: [date.timeIntervalSince1970])
            try Self.trimMilestones(db, sessionID: nil)
        }
    }

    /// Keeps the newest `milestonesPerSession` of one session (nil: of every
    /// session).
    private static func trimMilestones(_ db: Database, sessionID: Int64?) throws {
        try db.execute(
            sql: """
                DELETE FROM session_milestones WHERE rowid IN (
                    SELECT rowid FROM (
                        SELECT rowid, ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY at DESC, rowid DESC) AS rank
                        FROM session_milestones WHERE ?1 IS NULL OR session_id = ?1
                    ) WHERE rank > ?2
                )
                """,
            arguments: [sessionID, milestonesPerSession]
        )
    }

    // MARK: - Ask alerts (spec §4.7)

    /// When an ask's `ask_alert` was first written, and in which sync
    /// generation: an alert is published only in the generation that wrote
    /// it. A reset forgets an unconfirmed alert of the wiped generation (no
    /// recorded hash, within the lifetime) so it is stamped again; every
    /// other row is kept, so a new account's zone never gets an alert the
    /// old zone got.
    struct AlertedAsk: Equatable, Sendable {
        let at: Date
        let generation: Int
    }

    /// Remembers each of `askIDs` not alerted yet as alerted at `date` in
    /// the current generation (a remembered one keeps its first stamp), and
    /// returns that generation with every remembered ask. One write
    /// transaction, so two cycles never alert one ask twice and a reset
    /// cannot land between the stamp and the generation it is compared to.
    func markAlerted(_ askIDs: [Int64], at date: Date) throws -> (generation: Int, alerted: [Int64: AlertedAsk]) {
        try queue.write { db in
            let generation = try Self.generation(db)
            for id in askIDs {
                try db.execute(
                    sql: "INSERT INTO alerted_asks (ask_id, at, generation) VALUES (?, ?, ?) ON CONFLICT(ask_id) DO NOTHING",
                    arguments: [id, date.timeIntervalSince1970, generation]
                )
            }
            return (generation, try Self.fetchAlerted(db))
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

    // MARK: - Linking (spec §2.3, §10)

    /// One QR code the hub issued. Single use: `usedByDevice` is set once.
    struct LinkCode: Equatable, Sendable {
        let nonce: String
        let issuedAt: Date
        let exp: Date
        let usedByDevice: String?
    }

    /// One linked phone (the `devices` table, spec §10).
    struct LinkedDevice: Equatable, Sendable {
        let deviceID: String
        /// At most `DevicePayload.maxNameLength` grapheme clusters.
        let name: String
        let scope: DeviceScope
        let userRecordName: String
        let linkedAt: Date
        var typingAllowed = false
        var startSessionsAllowed = true
        /// When the owner last changed a grant; nil while undecided.
        var decidedAt: Date?

        /// The device gate's creator check (spec §5.2 rule 4): in `shared`
        /// scope a record must be written by the phone's own iCloud user.
        /// A `private` phone writes as the Mac's user, which CloudKit reports
        /// as `CKCurrentUserDefaultName` (or the user's own name); nil is a
        /// record whose creator is unknown (the in-memory transport, an
        /// event buffered before creators were kept): `private` only.
        func accepts(creator: String?) -> Bool {
            if scope == .shared { return creator == userRecordName }
            guard let creator else { return true }
            return creator == CKCurrentUserDefaultName || creator == userRecordName
        }
    }

    /// A refused link attempt, published as `device_grant` with `link_refused`.
    struct LinkRefusalRecord: Equatable, Sendable {
        let deviceID: String
        let name: String
        let scope: DeviceScope
        let reason: LinkRefusal
        let at: Date
    }

    /// What a nonce does for a device.
    enum LinkDecision: Equatable, Sendable {
        /// Known, unused and `exp ≥ now`.
        case valid
        /// The same nonce from the same device again (idempotent).
        case alreadyUsedByThisDevice
        case refused(LinkRefusal)

        static func of(_ code: LinkCode?, deviceID: String, now: Date) -> Self {
            guard let code else { return .refused(.unknownCode) }
            if let used = code.usedByDevice { return used == deviceID ? .alreadyUsedByThisDevice : .refused(.usedCode) }
            return code.exp >= now ? .valid : .refused(.expiredCode)
        }
    }

    /// Stores a fresh code, then keeps the newest `keeping` codes.
    func addLinkCode(nonce: String, issuedAt: Date, exp: Date, keeping: Int) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO link_codes (nonce, issued_at, exp) VALUES (?, ?, ?)",
                arguments: [nonce, issuedAt.timeIntervalSince1970, exp.timeIntervalSince1970]
            )
            try db.execute(
                sql: """
                    DELETE FROM link_codes WHERE nonce NOT IN (
                        SELECT nonce FROM link_codes ORDER BY issued_at DESC, rowid DESC LIMIT ?
                    )
                    """,
                arguments: [keeping]
            )
        }
    }

    func linkCode(_ nonce: String) throws -> LinkCode? {
        try queue.read { try Self.fetchLinkCode(nonce, $0) }
    }

    /// Every stored code, newest first.
    func linkCodes() throws -> [LinkCode] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM link_codes ORDER BY issued_at DESC, rowid DESC").map(Self.linkCode)
        }
    }

    /// Links `device` with `nonce` in one transaction: the decision is
    /// re-checked there, and only a `.valid` one marks the code used by the
    /// device, upserts its row (a re-link keeps the owner's grants) and
    /// forgets its refusal. Returns the decision it found.
    func linkDevice(_ device: LinkedDevice, nonce: String, now: Date) throws -> LinkDecision {
        try queue.write { db in
            let decision = LinkDecision.of(try Self.fetchLinkCode(nonce, db), deviceID: device.deviceID, now: now)
            guard decision == .valid else { return decision }
            try db.execute(
                sql: "UPDATE link_codes SET used_by_device = ?, used_at = ? WHERE nonce = ?",
                arguments: [device.deviceID, now.timeIntervalSince1970, nonce]
            )
            try db.execute(
                sql: """
                    INSERT INTO devices (device_id, name, scope, user_record_name, linked_at, typing_allowed,
                                         start_sessions_allowed, decided_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(device_id) DO UPDATE SET
                        name = excluded.name, scope = excluded.scope,
                        user_record_name = excluded.user_record_name, linked_at = excluded.linked_at
                    """,
                arguments: [
                    device.deviceID, device.name, device.scope.rawValue, device.userRecordName,
                    device.linkedAt.timeIntervalSince1970, device.typingAllowed, device.startSessionsAllowed,
                    device.decidedAt?.timeIntervalSince1970
                ]
            )
            try db.execute(sql: "DELETE FROM link_refusals WHERE device_id = ?", arguments: [device.deviceID])
            return .valid
        }
    }

    func linkedDevice(_ deviceID: String) throws -> LinkedDevice? {
        try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM devices WHERE device_id = ?", arguments: [deviceID]).map(Self.device)
        }
    }

    /// Every linked phone, oldest link first (two phones of one name are
    /// told apart by `linkedAt`).
    func linkedDevices() throws -> [LinkedDevice] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM devices ORDER BY linked_at, device_id").map(Self.device)
        }
    }

    /// Deletes the device's row and refusal; the removed row, nil when it
    /// was not linked.
    func removeLinkedDevice(_ deviceID: String) throws -> LinkedDevice? {
        try queue.write { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM devices WHERE device_id = ?", arguments: [deviceID])
            try db.execute(sql: "DELETE FROM devices WHERE device_id = ?", arguments: [deviceID])
            try db.execute(sql: "DELETE FROM link_refusals WHERE device_id = ?", arguments: [deviceID])
            return row.map(Self.device)
        }
    }

    /// A grant the owner decides per phone (spec §10).
    enum DeviceGrantKind: String {
        case typing = "typing_allowed"
        case startSessions = "start_sessions_allowed"
    }

    /// Sets one grant of a linked device and stamps `decided_at`. False
    /// when the device is not linked.
    func setDeviceGrant(_ grant: DeviceGrantKind, _ allowed: Bool, deviceID: String, at date: Date) throws -> Bool {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE devices SET \(grant.rawValue) = ?, decided_at = ? WHERE device_id = ?",
                arguments: [allowed, date.timeIntervalSince1970, deviceID]
            )
            return db.changesCount > 0
        }
    }

    func saveLinkRefusal(_ refusal: LinkRefusalRecord) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO link_refusals (device_id, name, scope, reason, at) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(device_id) DO UPDATE SET
                        name = excluded.name, scope = excluded.scope, reason = excluded.reason, at = excluded.at
                    """,
                arguments: [
                    refusal.deviceID, refusal.name, refusal.scope.rawValue, refusal.reason.rawValue,
                    refusal.at.timeIntervalSince1970
                ]
            )
        }
    }

    /// Every remembered refusal, newest first.
    func linkRefusals() throws -> [LinkRefusalRecord] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM link_refusals ORDER BY at DESC, device_id").map { row in
                LinkRefusalRecord(
                    deviceID: row["device_id"], name: row["name"], scope: DeviceScope(rawValue: row["scope"]),
                    reason: LinkRefusal(rawValue: row["reason"]), at: Date(timeIntervalSince1970: row["at"])
                )
            }
        }
    }

    func pruneLinkRefusals(olderThan date: Date) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM link_refusals WHERE at < ?", arguments: [date.timeIntervalSince1970])
        }
    }

    /// Take over (spec §2.3): forgets every code, linked phone and refusal.
    func clearLinkState() throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM link_codes; DELETE FROM devices; DELETE FROM link_refusals")
        }
    }

    private static func fetchLinkCode(_ nonce: String, _ db: Database) throws -> LinkCode? {
        try Row.fetchOne(db, sql: "SELECT * FROM link_codes WHERE nonce = ?", arguments: [nonce]).map(linkCode)
    }

    private static func linkCode(_ row: Row) -> LinkCode {
        LinkCode(
            nonce: row["nonce"],
            issuedAt: Date(timeIntervalSince1970: row["issued_at"]),
            exp: Date(timeIntervalSince1970: row["exp"]),
            usedByDevice: row["used_by_device"]
        )
    }

    private static func device(_ row: Row) -> LinkedDevice {
        LinkedDevice(
            deviceID: row["device_id"],
            name: row["name"],
            scope: DeviceScope(rawValue: row["scope"]),
            userRecordName: row["user_record_name"],
            linkedAt: Date(timeIntervalSince1970: row["linked_at"]),
            typingAllowed: row["typing_allowed"],
            startSessionsAllowed: row["start_sessions_allowed"],
            decidedAt: (row["decided_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        )
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
    /// are kept too, and so are the alerted asks whose alert has a recorded
    /// hash: the new account's zone must not get an alert for an ask alerted
    /// before (spec §4.7). An alert of the generation being wiped, written
    /// within the alert lifetime of `now`, without one (its cycle aborted or
    /// its save failed) is forgotten, so the next cycle stamps it in the new
    /// generation and publishes it; older-generation and expired rows stay.
    /// Accepted trade-off — a duplicate beats a lost alert: an alert saved
    /// before its hash was recorded, or one whose record left the zone with
    /// its workbench, may alert once more in the new zone.
    /// The generation counter is bumped so an in-flight publish cycle can
    /// detect the reset and abort before recording stale hashes.
    ///
    /// `keepingRelayToken`: a server-side DataZone deletion (no account
    /// change) lost the published records but not the relay buffer, so the
    /// relay cursor stays — rewinding it would re-read relay records the
    /// ledger lets through again (a failed upload is re-ingested, a received
    /// one re-echoed).
    func wipeSyncState(now: Date, keepingRelayToken: Bool = false) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    DELETE FROM alerted_asks WHERE generation = ? AND at >= ? AND NOT EXISTS (
                        SELECT 1 FROM slice_state WHERE record_name = ? || alerted_asks.ask_id
                    )
                    """,
                arguments: [
                    try Self.generation(db),
                    now.addingTimeInterval(-AskAlertSlice.lifetime).timeIntervalSince1970,
                    SliceKind.askAlert.recordName(id: "")
                ]
            )
            try db.execute(sql: "DELETE FROM slice_state")
            let relayKeys = keepingRelayToken ? [] : [RelayProcessor.relayTokenKey]
            for key in relayKeys + HubIdentity.heartbeatReadKeys {
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

    /// The sync generation counter: 0 until the first `wipeSyncState(now:)`.
    func generation() throws -> Int {
        try queue.read(Self.generation)
    }

    private static func generation(_ db: Database) throws -> Int {
        let raw = try String.fetchOne(db, sql: "SELECT value FROM hub_meta WHERE key = ?", arguments: [generationKey])
        return raw.flatMap(Int.init) ?? 0
    }
}

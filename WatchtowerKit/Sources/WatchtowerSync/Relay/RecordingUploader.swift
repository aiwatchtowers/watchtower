import Foundation
import os

/// The seam through which `RelayFeed` hands recording-upload echoes onward.
/// `RecordingUploader` conforms; the feed is written against the protocol so
/// tests can observe routing directly.
///
/// Delivery contract: the feed calls `applyEcho` for
/// every decodable non-pending `recording_upload` record in batch order,
/// BEFORE the relay token is persisted — a throw aborts the cycle with the
/// token untouched, so the batch replays next poll. `applyEcho` must
/// therefore be idempotent per record.
public protocol RecordingUploadAcking: Sendable {
    func applyEcho(_ upload: RecordingUploadPayload) async throws
}

/// The phone's recording-upload state machine over the `phone_recordings`
/// ledger in `ReplicaStore`. States: waiting → uploading → delivered/failed.
///
/// Durability rules (the plan's invariants):
/// - a recording registers ONLY after its file is final on disk — the ledger
///   row plus the file survive an app kill;
/// - mobile E2E: a finalized recording is sealed ONCE (`sealPending`): the
///   audio is encrypted to `<id>.enc` under a fresh asset key, the upload
///   record (asset descriptor inside) is sealed by `SecureTransport`, the
///   envelope, its wire name and the sealed file are stored in one row
///   update. Only ciphertext ever leaves the phone; the plain audio stays
///   on the phone (under its `completeUnlessOpen` file protection) until
///   the Mac confirms receipt — owner ruling ask #89, option A — so the
///   hold across a wipe (board #63) can carry it to a new link, where it is
///   sealed fresh. A locked keychain leaves the row `waiting` with its
///   plain file; it is sealed after unlock;
/// - every send — the first, the relaunch retry, Retry after a failed echo —
///   saves the STORED envelope and the same sealed file (`saveSealed`), never
///   a re-seal, so the hub sees one record version (Review Focus 2);
/// - the plain and the sealed file are deleted ONLY on a `received` echo
///   from the hub (ack-then-delete) or the owner's discard; a `failed` echo
///   keeps both;
/// - a new `waiting` row goes out on the next pass once it is sealed (see
///   Sealing). Every save counts an attempt (`upload_attempts`,
///   `last_attempt_at`); a row saved before is saved again only when its
///   backoff is due (`retryDelays` after its latest attempt), only while
///   `retriesAllowed` holds (the app is in the foreground — never on a
///   launch into the background), and at most
///   `PhoneRecording.uploadAttemptCap` times: past it the row reads "Upload
///   stuck" until the owner's Retry, which resets the backoff. Every save
///   of a row sends its stored envelope byte for byte (mobile E2E);
/// - an `uploading` row already sits in the transport's durable send
///   queue, so it is re-saved (the relaunch retry: the same envelope
///   upserts the same record, and the hub's ledger absorbs true
///   duplicates) only by the first foreground pass of a process that finds
///   the Mac online (`macOnline`), when due — or by the next foreground
///   pass after `resendInFlightAfterWipe()`, due or not and whatever the
///   Mac. While the Mac sleeps the queue holds the row for it: a re-save
///   would only spend attempts toward "Upload stuck", so none is made or
///   counted.
public actor RecordingUploader: RecordingUploadAcking {
    /// Recordings shorter than this are degenerate (a tap on Record followed
    /// by an immediate stop) and are discarded without a ledger row.
    public static let minimumDurationSec: TimeInterval = 1
    /// The capture format descriptor stamped into the wire payload.
    public static let sampleFormat = "aac-64k-mono"
    /// The asset cap (spec §3): 3 h of 64 kbps AAC is about 86 MB.
    public static let maximumAssetBytes: Int64 = 90_000_000
    /// The ledger message for a file over the asset cap.
    public static let tooLargeMessage = "This recording is over 90 MB, too large to send to your Mac."
    /// The ledger message for a row whose audio file is gone.
    public static let missingFileMessage = "The local audio file is missing."
    /// The ledger message for a capture that holds no readable audio.
    public static let unrecoverableMessage = "The recording stopped before any audio was saved."
    /// The wait after the Nth attempt before attempt N + 1 (board #724):
    /// 1 min, 5 min, 30 min, 2 h, 6 h. With the cap of 6 attempts the
    /// last delay is the one before the sixth.
    public static let retryDelays: [TimeInterval] = [60, 300, 1_800, 7_200, 21_600]

    /// When a row with `attempts` saves behind it, the latest at `last`, may
    /// be saved again; nil once the cap is reached. A row never saved is
    /// due at once.
    public static func nextAttemptAt(attempts: Int, last: Date?) -> Date? {
        guard attempts < PhoneRecording.uploadAttemptCap else { return nil }
        guard attempts > 0, let last else { return .distantPast }
        let delay = retryDelays[min(attempts, retryDelays.count) - 1]
        return last.addingTimeInterval(delay)
    }

    /// The message shown for a local failure.
    public static func message(for failure: PhoneRecording.LocalFailure) -> String {
        switch failure {
        case .missingFile: missingFileMessage
        case .tooLarge: tooLargeMessage
        case .unrecoverable: unrecoverableMessage
        }
    }

    /// The recordings folder. A file inside it is stored by name only and
    /// resolved against this folder at use, so the ledger survives iOS
    /// moving the app's container. nil keeps absolute paths (and turns the
    /// orphan sweep off).
    nonisolated public let directory: URL?

    private let transport: SecureTransport
    private let store: ReplicaStore
    private let maxAssetBytes: Int64
    private let now: @Sendable () -> Date
    /// Whether a pass may save a row saved before: true only while the app
    /// is in the foreground (the environment's scene phase). A pass where
    /// it is false sends new rows only and keeps the relaunch retry armed.
    private let retriesAllowed: @Sendable () -> Bool
    /// Whether the Mac reads online (its heartbeat is fresh): the relaunch
    /// re-save of `uploading` rows waits for it.
    private let macOnline: @Sendable () -> Bool
    /// Counts each upload attempt (the phone's battery diagnostics).
    private let energy: EnergyCounter?
    /// The linked phone's device id, stamped on every upload. nil until
    /// linking finishes (or after an unlink): uploads then wait, because the
    /// hub fails a record without one as `device_not_linked`. A blank id
    /// counts as none (`linkedDeviceID`).
    private var deviceID: String?
    /// Captures this uploader began and has not finished: launch recovery
    /// never touches them, however recovery and a Record tap interleave.
    /// A new process starts empty, so a capture cut short is recovered.
    private var liveCaptureIDs: Set<String> = []
    /// Recordings being sealed now (the actor suspends inside `sealRow`): a
    /// second seal of one recording would overwrite the same `<id>.enc`.
    private var sealingIDs: Set<String> = []
    private var ledgerPrepared = false
    /// Whether the next foreground pass re-saves `uploading` rows: true
    /// for the first pass of a process (the relaunch retry) and after a
    /// transport wipe.
    private var resendInFlight = true
    /// Set by a wipe: the queue that held the `uploading` rows is gone, so
    /// they are re-saved without waiting for their backoff.
    private var resendIgnoresBackoff = false
    /// The pass sending now, and the one queued behind it: callers that
    /// overlap a running pass join the queued one, so no two passes ever
    /// send at once.
    private var runningPass: Task<Int, Error>?
    private var queuedPass: Task<Int, Error>?
    private let logger = Logger(subsystem: "WatchtowerKit", category: "RecordingUploader")

    public init(
        transport: SecureTransport,
        store: ReplicaStore,
        directory: URL? = nil,
        deviceID: String? = nil,
        maxAssetBytes: Int64 = RecordingUploader.maximumAssetBytes,
        now: @escaping @Sendable () -> Date = { Date() },
        retriesAllowed: @escaping @Sendable () -> Bool = { true },
        macOnline: @escaping @Sendable () -> Bool = { true },
        energy: EnergyCounter? = nil
    ) {
        self.transport = transport
        self.store = store
        self.directory = directory
        self.deviceID = linkedDeviceID(deviceID)
        self.maxAssetBytes = maxAssetBytes
        self.now = now
        self.retriesAllowed = retriesAllowed
        self.macOnline = macOnline
        self.energy = energy
    }

    /// Called by the link flow once the device is linked, and with nil on
    /// unlink. Waiting recordings go out on the next `uploadPending`.
    public func setDeviceID(_ deviceID: String?) {
        self.deviceID = linkedDeviceID(deviceID)
    }

    // MARK: - Paths

    private func fileURL(_ row: PhoneRecording) -> URL {
        row.fileURL(in: directory)
    }

    /// The name inside the recordings folder, or the absolute path of a
    /// file kept elsewhere.
    private func storedPath(for fileURL: URL) -> String {
        if let directory,
           fileURL.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path {
            return fileURL.lastPathComponent
        }
        return fileURL.path
    }

    /// One-time upgrade of rows written before this build:
    /// - an absolute path into a folder named like the recordings folder
    ///   (an older container's) becomes the bare file name;
    /// - a local failure recorded only by its message gets its kind.
    /// Every entry point that resolves a row's file runs it first (an echo
    /// can arrive before launch recovery); a failed upgrade is retried by
    /// the next call.
    private func prepareLedger() throws {
        guard !ledgerPrepared else { return }
        let legacyKinds: [String: PhoneRecording.LocalFailure] = [
            Self.missingFileMessage: .missingFile,
            Self.tooLargeMessage: .tooLarge,
            Self.unrecoverableMessage: .unrecoverable
        ]
        for row in try store.phoneRecordings() {
            if let directory, row.storedPath.hasPrefix("/") {
                let legacy = URL(fileURLWithPath: row.storedPath)
                if legacy.deletingLastPathComponent().lastPathComponent == directory.lastPathComponent {
                    try store.setPhoneRecordingPath(id: row.id, storedPath: legacy.lastPathComponent)
                }
            }
            if row.state == .failed, row.failure == nil, let kind = legacyKinds[row.errorMessage ?? ""] {
                try store.setPhoneRecordingState(id: row.id, state: .failed, errorMessage: row.errorMessage, failure: kind)
            }
        }
        ledgerPrepared = true
    }

    private func failLocally(_ id: String, _ failure: PhoneRecording.LocalFailure) throws {
        try store.setPhoneRecordingState(id: id, state: .failed, errorMessage: Self.message(for: failure), failure: failure)
    }

    // MARK: - Register (capture finalized)

    /// Adds a finalized recording to the ledger as `waiting`. Returns nil —
    /// and deletes the file — for degenerate captures: a missing/empty file
    /// or a duration under `minimumDurationSec`. Callers follow up with
    /// `uploadPending()` to hand the new row to the transport.
    ///
    /// - `id`: the ledger id; a new UUID when nil (a fixed id keeps a demo
    ///   row stable across launches).
    /// - `activeDuration`: the recorded audio length when the capture was
    ///   paused (an interruption or the Pause button); the wall-clock span
    ///   `endedAt - startedAt` is used when nil.
    /// - `eventID`: the calendar event a "Record this meeting" capture
    ///   belongs to; nil (or blank) for a voice note.
    /// - `marks`: mark-moment offsets in seconds of recorded audio, stored
    ///   locally only.
    @discardableResult
    public func register(
        id: String? = nil,
        fileURL: URL,
        startedAt: Date,
        endedAt: Date,
        activeDuration: TimeInterval? = nil,
        titleHint: String?,
        eventID: String? = nil,
        marks: [Int] = []
    ) throws -> PhoneRecording? {
        let duration = activeDuration ?? endedAt.timeIntervalSince(startedAt)
        guard isUsableCapture(fileURL, duration: duration) else { return nil }
        let recordingID = id ?? UUID().uuidString
        // A held recording registered again after a re-link (board #63) is
        // sealed fresh: a copy sealed under the old pairing is dropped. A
        // row still holding the id keeps its copy (the insert below fails).
        if try store.phoneRecording(id: recordingID) == nil {
            removeSealedLeftover(sealTarget(id: recordingID, plain: fileURL))
        }
        let recording = PhoneRecording(
            id: recordingID,
            storedPath: storedPath(for: fileURL),
            startedAt: startedAt,
            endedAt: endedAt,
            durationSec: Int(duration.rounded()),
            titleHint: Self.nonBlank(titleHint),
            sampleFormat: Self.sampleFormat,
            state: .waiting,
            errorMessage: nil,
            eventID: Self.nonBlank(eventID),
            failure: nil,
            uploadAttempts: 0,
            lastAttemptAt: nil,
            autoFinished: false
        )
        try store.insertPhoneRecording(recording, marks: marks)
        return recording
    }

    /// false — and the file is deleted — for a missing or empty file or a
    /// duration under `minimumDurationSec`.
    private func isUsableCapture(_ fileURL: URL, duration: TimeInterval) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        guard size > 0, duration >= Self.minimumDurationSec else {
            try? FileManager.default.removeItem(at: fileURL)
            logger.notice("degenerate recording discarded (size \(size), \(duration, format: .fixed(precision: 2)) s)")
            return false
        }
        return true
    }

    // MARK: - Capture lifecycle (a row from the first second)

    /// Inserts the ledger row of a capture that is starting, in the
    /// `recording` state, before any audio is written: a capture cut short
    /// by a kill is then found at the next launch. The id is marked live
    /// in the same actor turn, so recovery in this process never claims it.
    public func beginCapture(
        fileURL: URL,
        startedAt: Date,
        titleHint: String?,
        eventID: String?
    ) throws -> PhoneRecording {
        let recording = PhoneRecording(
            id: UUID().uuidString,
            storedPath: storedPath(for: fileURL),
            startedAt: startedAt,
            endedAt: startedAt,
            durationSec: 0,
            titleHint: Self.nonBlank(titleHint),
            sampleFormat: Self.sampleFormat,
            state: .recording,
            errorMessage: nil,
            eventID: Self.nonBlank(eventID),
            failure: nil,
            uploadAttempts: 0,
            lastAttemptAt: nil,
            autoFinished: false
        )
        liveCaptureIDs.insert(recording.id)
        do {
            try store.insertPhoneRecording(recording)
        } catch {
            liveCaptureIDs.remove(recording.id)
            throw error
        }
        return recording
    }

    /// Stores one mark-moment offset of a running capture as it is tapped.
    public func addMark(id: String, offsetSec: Int) throws {
        try store.insertPhoneRecordingMark(id: id, offsetSec: offsetSec)
    }

    /// Finalizes a capture the owner stopped: the row becomes `waiting`
    /// with the recorded length, the final title and event, and every mark
    /// (re-inserting a stored one is a no-op). Returns nil — removing the
    /// row and the file — for a capture under `minimumDurationSec`.
    /// `autoFinished` marks a capture the recorder ended after a long pause.
    @discardableResult
    public func finishCapture(
        id: String,
        endedAt: Date,
        activeDuration: TimeInterval,
        titleHint: String?,
        eventID: String?,
        marks: [Int] = [],
        autoFinished: Bool = false
    ) throws -> PhoneRecording? {
        liveCaptureIDs.remove(id)
        guard let row = try store.phoneRecording(id: id), row.state == .recording else { return nil }
        guard isUsableCapture(fileURL(row), duration: activeDuration) else {
            try store.removePhoneRecording(id: id)
            return nil
        }
        for offset in marks {
            try store.insertPhoneRecordingMark(id: id, offsetSec: offset)
        }
        try store.finalizePhoneRecording(
            id: id,
            endedAt: endedAt,
            durationSec: Int(activeDuration.rounded()),
            titleHint: Self.nonBlank(titleHint),
            eventID: Self.nonBlank(eventID),
            autoFinished: autoFinished
        )
        return try store.phoneRecording(id: id)
    }

    /// Ends a capture whose file holds no readable audio (the writer died
    /// before its first fragment): `failed` as unrecoverable, never
    /// uploaded, no Retry, and the useless file is deleted.
    public func failCapture(id: String) throws {
        liveCaptureIDs.remove(id)
        guard let row = try store.phoneRecording(id: id) else { return }
        try? FileManager.default.removeItem(at: fileURL(row))
        try failLocally(id, .unrecoverable)
    }

    /// Launch recovery: every row still `recording` that this uploader did
    /// not begin belongs to a capture cut short (kill, jetsam, crash). Each
    /// is finalized from its file:
    /// - the file plays → `waiting`, with the duration `durationOf` reads
    ///   from it (audio up to the last written fragment);
    /// - the file is gone → `failed` (missing file, no Retry);
    /// - the file has no readable audio → `failed` (unrecoverable, no
    ///   Retry), and the useless file is deleted;
    /// - under a second of audio → removed, like a too-short stop.
    /// Returns the recordings it made ready to upload.
    @discardableResult
    public func recoverInterruptedCaptures(
        durationOf: @Sendable (URL) async -> TimeInterval?
    ) async throws -> [PhoneRecording] {
        try prepareLedger()
        let stranded = try store.phoneRecordings().filter { $0.state == .recording && !liveCaptureIDs.contains($0.id) }
        var recovered: [PhoneRecording] = []
        for row in stranded {
            let file = fileURL(row)
            guard FileManager.default.fileExists(atPath: file.path) else {
                try failLocally(row.id, .missingFile)
                continue
            }
            guard let duration = await durationOf(file) else {
                try? FileManager.default.removeItem(at: file)
                try failLocally(row.id, .unrecoverable)
                continue
            }
            guard isUsableCapture(file, duration: duration) else {
                try store.removePhoneRecording(id: row.id)
                continue
            }
            try store.finalizePhoneRecording(
                id: row.id,
                endedAt: row.startedAt.addingTimeInterval(duration),
                durationSec: Int(duration.rounded()),
                titleHint: row.titleHint,
                eventID: row.eventID
            )
            logger.notice("recovered a capture cut short: \(row.id, privacy: .public), \(Int(duration)) s")
            if let finalized = try store.phoneRecording(id: row.id) {
                recovered.append(finalized)
            }
        }
        return recovered
    }

    /// Deletes every file in the recordings folder that no undelivered
    /// ledger row points at (a capture whose row never got written, audio
    /// a `received` echo failed to delete, or a leftover). Rows are matched
    /// by their path resolved against the CURRENT folder.
    /// Runs at launch, after recovery. Returns the deleted files.
    @discardableResult
    public func sweepOrphanFiles() throws -> [URL] {
        guard let directory else { return [] }
        try prepareLedger()
        // An undelivered row owns its plain file (kept until the Mac
        // confirms it, ask #89 A) AND its sealed copy: the stored one, or
        // `<id>.enc` that a seal in progress (suspended in `transport.seal`,
        // before `sealed_path` is stored) has already written.
        var known: Set<String> = []
        for row in try store.phoneRecordings() where row.state != .delivered {
            known.insert(fileURL(row).standardizedFileURL.path)
            known.insert((row.sealedFileURL(in: directory) ?? sealTarget(for: row)).standardizedFileURL.path)
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var removed: [URL] = []
        for file in files where !known.contains(file.standardizedFileURL.path) {
            do {
                try FileManager.default.removeItem(at: file)
                removed.append(file)
            } catch {
                logger.warning("orphan recording not removed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !removed.isEmpty {
            logger.notice("removed \(removed.count) orphan recording files")
        }
        return removed
    }

    private static func nonBlank(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    // MARK: - Upload

    /// Seals what is not sealed yet (`sealPending`, on every pass, the
    /// background ones included), then saves every sealed row that is due
    /// (see the type's rules) into the relay zone as its stored envelope
    /// with the sealed audio attached; a successful save flips the row to
    /// `uploading`. The first foreground pass of a process (and the first
    /// after `resendInFlightAfterWipe()`) re-sends due `uploading` rows too
    /// — the relaunch retry: the same envelope upserts the same record and
    /// the hub's ledger absorbs duplicates — once the Mac reads online (a
    /// wipe's re-send does not wait). Each save counts an attempt. A
    /// transport throw leaves the row for its next due pass; a vanished
    /// local file, or audio over the asset cap, fails the row locally (it
    /// can never be sent). Without a linked device nothing is sealed or sent
    /// and every row keeps waiting.
    /// A call while a pass is sending waits for it and runs one more pass,
    /// shared by every caller that arrived meanwhile.
    /// Returns how many rows were handed to the transport.
    @discardableResult
    public func uploadPending() async throws -> Int {
        if let queuedPass {
            return try await queuedPass.value
        }
        guard let previous = runningPass else {
            let pass = Task { try await self.runPass() }
            runningPass = pass
            return try await pass.value
        }
        let pass = Task {
            _ = try? await previous.value
            return try await self.runQueuedPass()
        }
        queuedPass = pass
        return try await pass.value
    }

    /// Called by the transport's wipe path (an account reset discards the
    /// send queue): the next pass re-sends every `uploading` row.
    public func resendInFlightAfterWipe() {
        resendInFlight = true
        resendIgnoresBackoff = true
    }

    private func runQueuedPass() async throws -> Int {
        runningPass = queuedPass
        queuedPass = nil
        return try await runPass()
    }

    private func runPass() async throws -> Int {
        defer { runningPass = nil }
        return try await sendPending()
    }

    private func sendPending() async throws -> Int {
        guard let deviceID else {
            logger.notice("recording uploads wait: this phone is not linked")
            return 0
        }
        try prepareLedger()
        // A background pass sends new rows only and leaves the relaunch
        // retry armed for the first foreground one; so does a pass while
        // the Mac is offline, unless a wipe emptied the queue.
        let retrying = retriesAllowed()
        let includeInFlight = retrying && resendInFlight && (resendIgnoresBackoff || macOnline())
        let ignoreBackoff = includeInFlight && resendIgnoresBackoff
        if includeInFlight {
            resendInFlight = false
            resendIgnoresBackoff = false
        }
        do {
            // A non-lock seal error is per row (logged in `sealRows`): rows
            // already sealed are still sent below.
            let justSealed = try await sealRows(deviceID: deviceID).sealedInFlight
            let rows = try store.phoneRecordings().filter {
                guard $0.isSealed else { return false }
                // A pre-E2E `uploading` row sealed by this pass was never
                // sent sealed: it goes out like a new row.
                if $0.state == .uploading, justSealed.contains($0.id) { return true }
                return isDue($0, retrying: retrying, includeInFlight: includeInFlight, ignoreBackoff: ignoreBackoff)
            }
            return try await send(rows)
        } catch {
            // A pass that exits by throwing (a store read or write) has not
            // finished its re-send: keep it armed for the next pass instead
            // of stranding `uploading` rows until the next launch. At worst
            // a row it already re-saved goes out once more.
            if includeInFlight {
                resendInFlight = true
                resendIgnoresBackoff = resendIgnoresBackoff || ignoreBackoff
            }
            throw error
        }
    }

    /// Whether this pass saves `row`: a never-saved `waiting` row always; a
    /// row saved before only while retrying, under the cap, and once its
    /// backoff is due (a wipe's re-send skips the wait); an `uploading` row
    /// only on the pass that re-sends in-flight rows.
    private func isDue(_ row: PhoneRecording, retrying: Bool, includeInFlight: Bool, ignoreBackoff: Bool) -> Bool {
        switch row.state {
        case .waiting:
            guard row.uploadAttempts > 0 else { return true }
        case .uploading:
            guard includeInFlight else { return false }
        case .recording, .delivered, .failed:
            return false
        }
        guard retrying, let due = Self.nextAttemptAt(attempts: row.uploadAttempts, last: row.lastAttemptAt) else {
            return false
        }
        // A millisecond of slack: the ledger keeps Unix seconds as a REAL,
        // so a stored time reads back a hair off the clock's.
        return ignoreBackoff || due.timeIntervalSince(now()) <= 0.001
    }

    /// Saves each sealed row's stored envelope, unchanged.
    private func send(_ rows: [PhoneRecording]) async throws -> Int {
        var sent = 0
        for row in rows {
            guard let envelope = row.envelope, let wireName = row.wireName, let sealed = row.sealedFileURL(in: directory)
            else { continue }
            guard FileManager.default.fileExists(atPath: sealed.path) else {
                try failLocally(row.id, .missingFile)
                continue
            }
            let attemptAt = now()
            // Counted before the save, so an attempt the process dies in
            // still spends its backoff step. A store failure ends the pass.
            try store.recordPhoneRecordingUploadAttempt(id: row.id, at: attemptAt)
            let record = CloudRecord(
                recordName: wireName, zone: .relay, kind: WireKind.envelope, modifiedAt: attemptAt, payload: envelope,
                assetFileURL: sealed)
            do {
                energy?.record(.uploadAttempt)
                try await transport.saveSealed([record])
            } catch {
                // Transient failure: keep the row for its next due pass.
                logger.warning("""
                    recording upload save failed for \(row.id, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
                if row.state == .uploading {
                    resendInFlight = true
                }
                continue
            }
            try store.setPhoneRecordingState(id: row.id, state: .uploading)
            sent += 1
        }
        return sent
    }

    // MARK: - Sealing (mobile E2E)

    /// Seals every finalized recording that has no envelope yet (`waiting`,
    /// and an `uploading` row a pre-E2E build sent in the clear): the audio
    /// is encrypted to `<id>.enc` with a fresh asset key, the upload record
    /// is sealed once, and the envelope, wire name and sealed file are
    /// stored in one row update; the plain audio stays until the Mac
    /// confirms it (`applyEcho`, ask #89 A). The asset cap is
    /// checked on the plain size first. A locked keychain (or keys not here
    /// yet) stops the pass with the remaining rows untouched — plain file
    /// kept, retried by a later pass — and is not an error. Without a linked
    /// device nothing is sealed (the payload carries the device id).
    /// Returns how many recordings this call sealed. `uploadPending` runs it
    /// first.
    @discardableResult
    public func sealPending() async throws -> Int {
        guard let deviceID else {
            logger.notice("recording seals wait: this phone is not linked")
            return 0
        }
        try prepareLedger()
        return try await sealRows(deviceID: deviceID).sealed
    }

    /// `sealed`: how many rows this call sealed; `sealedInFlight`: the
    /// `uploading` rows (pre-E2E uploads) among them, which this pass sends
    /// although it may not be the launch pass. A locked keychain
    /// stops the loop; any other error is the row's, logged, and leaves that
    /// row unsealed for the next pass while the others go on.
    private func sealRows(deviceID: String) async throws -> (sealed: Int, sealedInFlight: Set<String>) {
        try unsealStaleEpochs()
        let rows = try store.phoneRecordings().filter {
            ($0.state == .waiting || $0.state == .uploading) && $0.envelope == nil
        }
        var sealedCount = 0
        var sealedInFlight: Set<String> = []
        for row in rows {
            do {
                guard try await sealRow(row, deviceID: deviceID) else { continue }
                sealedCount += 1
                if row.state == .uploading { sealedInFlight.insert(row.id) }
            } catch KeyStoreError.locked, SecureTransportError.keysUnavailable {
                logger.notice("recording seals wait for the keychain (\(rows.count - sealedCount) left)")
                break
            } catch {
                logger.error("""
                    recording not sealed, retried next pass: \(row.id, privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """)
            }
        }
        return (sealedCount, sealedInFlight)
    }

    /// Final review Kit I1: byte identity matters only within an epoch. A
    /// `waiting` or `uploading` row whose stored envelope was sealed under an
    /// epoch older than the phone's current one (rotations while it was
    /// away; the hub accepts the previous epoch for 7 days only) loses its
    /// seal here, so `sealRows` seals it again under the current epoch: the
    /// same wire name (`K_meta` does not rotate, so the hub's ledger still
    /// dedupes), a new envelope and a fresh asset key. Keys that cannot be
    /// read now leave every row as it is.
    private func unsealStaleEpochs() throws {
        let current: UInt32
        do {
            current = try transport.currentEpoch()
        } catch KeyStoreError.locked, SecureTransportError.keysUnavailable {
            return
        }
        let rows = try store.phoneRecordings().filter {
            ($0.state == .waiting || $0.state == .uploading) && $0.envelope != nil && !sealingIDs.contains($0.id)
        }
        for row in rows {
            guard let envelope = row.envelope else { continue }
            let epoch: UInt32
            do {
                epoch = try Envelope.parse(envelope).header.epoch
            } catch {
                logger.error("stored recording envelope unreadable: \(row.id, privacy: .public): \(String(describing: error), privacy: .public)")
                continue
            }
            guard epoch < current, try store.clearPhoneRecordingSeal(id: row.id, envelope: envelope) else { continue }
            logger.notice("recording \(row.id, privacy: .public) sealed under epoch \(epoch) is sealed again under \(current)")
        }
    }

    /// true when this call sealed the row; false when another call sealed
    /// (or is sealing) it, the row failed locally, could not be encrypted
    /// (retried next pass), or went away while it was being sealed.
    private func sealRow(_ snapshot: PhoneRecording, deviceID: String) async throws -> Bool {
        // Re-read and claim in one actor turn: the list was read before
        // earlier rows' suspensions, so an overlapping call may have sealed
        // this one meanwhile.
        guard !sealingIDs.contains(snapshot.id), let row = try store.phoneRecording(id: snapshot.id),
              row.envelope == nil, row.state == .waiting || row.state == .uploading
        else { return false }
        sealingIDs.insert(row.id)
        defer { sealingIDs.remove(row.id) }
        let plain = fileURL(row)
        guard let size = try? FileManager.default.attributesOfItem(atPath: plain.path)[.size] as? Int64 else {
            try failLocally(row.id, .missingFile)
            return false
        }
        guard size <= maxAssetBytes else {
            try failLocally(row.id, .tooLarge)
            return false
        }
        // Marks are deliberately absent: they stay on the phone.
        let payload = RecordingUploadPayload(
            id: row.id,
            startedAt: row.startedAt,
            endedAt: row.endedAt,
            durationSec: row.durationSec,
            titleHint: row.titleHint,
            sampleFormat: row.sampleFormat,
            eventID: row.eventID,
            deviceID: deviceID
        )
        let unsealed = try CloudRecordFactory.record(for: payload, modifiedAt: now(), assetFileURL: nil)
        // The opaque name needs `K_meta`: a locked keychain throws here,
        // before a large file is encrypted for nothing.
        _ = try transport.wireName(for: unsealed)
        let sealedFile = sealTarget(for: row)
        let descriptor: AssetDescriptor
        do {
            // A fresh asset key per call (`encryptFile`'s default).
            descriptor = try ChunkedAssetCipher.encryptFile(at: plain, to: sealedFile)
        } catch {
            logger.warning("""
                recording not sealed, retried next pass: \(row.id, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
            removeSealedLeftover(sealedFile)
            return false
        }
        let wire: CloudRecord
        do {
            wire = try await transport.seal(CloudRecord(
                recordName: unsealed.recordName, zone: unsealed.zone, kind: unsealed.kind,
                modifiedAt: unsealed.modifiedAt, payload: unsealed.payload, assetFileURL: sealedFile, asset: descriptor))
        } catch {
            // Never keep a sealed file without its envelope: its key is gone with this call.
            removeSealedLeftover(sealedFile)
            throw error
        }
        let stored: Bool
        do {
            stored = try store.setPhoneRecordingSealed(
                id: row.id, envelope: wire.payload, wireName: wire.recordName, sealedPath: storedPath(for: sealedFile))
        } catch {
            // No row holds the envelope: the sealed file goes, the plain file stays for the retry.
            removeSealedLeftover(sealedFile)
            throw error
        }
        guard stored else {
            // The row was discarded while this call encrypted it.
            removeSealedLeftover(sealedFile)
            return false
        }
        return true
    }

    /// Where `sealRow` writes a row's sealed audio: `<id>.enc` in the
    /// recordings folder, or next to a plain file kept elsewhere.
    private func sealTarget(for row: PhoneRecording) -> URL {
        sealTarget(id: row.id, plain: fileURL(row))
    }

    private func sealTarget(id: String, plain: URL) -> URL {
        (directory ?? plain.deletingLastPathComponent()).appendingPathComponent("\(id).enc")
    }

    private func removeSealedLeftover(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logger.warning("sealed leftover not removed (the orphan sweep retries): \(url.lastPathComponent, privacy: .public)")
        }
    }

    // MARK: - Echoes (via RelayFeed)

    /// Resolves the ledger from a hub echo. `received` deletes the local
    /// audio, sealed and plain (ack-then-delete), and marks the row
    /// delivered; `failed` keeps both files (the next Retry re-sends the
    /// sealed one with the stored envelope) and surfaces the hub's message. Unknown ids are no-ops
    /// (redelivery after the row was removed); a still-`pending` payload is
    /// our own save reflecting back: inert. Idempotent — a replayed batch
    /// re-applies the same terminal state and the file removal no-ops.
    public func applyEcho(_ upload: RecordingUploadPayload) async throws {
        try prepareLedger()
        switch upload.status {
        case .pending:
            break
        case .received:
            guard let row = try store.phoneRecording(id: upload.id) else { return }
            try store.setPhoneRecordingState(id: upload.id, state: .delivered)
            // Already gone (a replayed echo) is a no-op for either file.
            try? FileManager.default.removeItem(at: fileURL(row))
            if let sealed = row.sealedFileURL(in: directory) { try? FileManager.default.removeItem(at: sealed) }
        case .failed:
            // Never downgrade a delivered row — a late duplicate failed echo
            // after a successful re-upload must not resurrect the failure.
            guard let row = try store.phoneRecording(id: upload.id), row.state != .delivered else { return }
            try store.setPhoneRecordingState(
                id: upload.id, state: .failed,
                errorMessage: upload.errorMessage ?? "The Mac could not ingest this recording."
            )
        }
    }

    // MARK: - User affordances

    /// The owner's Retry on a `failed` row or one stuck past the attempt
    /// cap: back to `waiting` with a fresh backoff, then an upload pass. A
    /// local failure (`offersRetry` false) is left as it is.
    public func retryFailed(id: String) async throws {
        guard let row = try store.phoneRecording(id: id), row.offersRetry else { return }
        try store.resetPhoneRecordingForRetry(id: id)
        _ = try await uploadPending()
    }

    /// Removes a ledger row and its local files, plain and sealed (the
    /// user's delete). The
    /// relay record, if any, is left for the hub's hygiene.
    public func discard(id: String) throws {
        liveCaptureIDs.remove(id)
        try prepareLedger()
        guard let row = try store.phoneRecording(id: id) else { return }
        try store.removePhoneRecording(id: id)
        try? FileManager.default.removeItem(at: fileURL(row))
        if let sealed = row.sealedFileURL(in: directory) { try? FileManager.default.removeItem(at: sealed) }
    }
}

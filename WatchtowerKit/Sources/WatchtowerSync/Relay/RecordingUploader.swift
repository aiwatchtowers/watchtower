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
/// - the local file is deleted ONLY on a `received` echo from the hub
///   (ack-then-delete);
/// - a new `waiting` row goes out on the next pass. Every save counts an
///   attempt (`upload_attempts`, `last_attempt_at`); a row saved before is
///   saved again only when its backoff is due (`retryDelays` after its
///   latest attempt), only while `retriesAllowed` holds (the app is in the
///   foreground — never on a launch into the background), and at most
///   `PhoneRecording.uploadAttemptCap` times: past it the row reads "Upload
///   stuck" until the owner's Retry, which resets the backoff;
/// - an `uploading` row already sits in the transport's durable send
///   queue, so it is re-saved (the relaunch retry: the same recordName
///   upserts, and the hub's processed-set absorbs true duplicates) only by
///   the first foreground pass of a process, when due — or by the next
///   foreground pass after `resendInFlightAfterWipe()`, due or not.
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

    private let transport: any CloudSyncTransport
    private let store: ReplicaStore
    private let maxAssetBytes: Int64
    private let now: @Sendable () -> Date
    /// Whether a pass may save a row saved before: true only while the app
    /// is in the foreground (the environment's scene phase). A pass where
    /// it is false sends new rows only and keeps the relaunch retry armed.
    private let retriesAllowed: @Sendable () -> Bool
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
        transport: any CloudSyncTransport,
        store: ReplicaStore,
        directory: URL? = nil,
        deviceID: String? = nil,
        maxAssetBytes: Int64 = RecordingUploader.maximumAssetBytes,
        now: @escaping @Sendable () -> Date = { Date() },
        retriesAllowed: @escaping @Sendable () -> Bool = { true },
        energy: EnergyCounter? = nil
    ) {
        self.transport = transport
        self.store = store
        self.directory = directory
        self.deviceID = linkedDeviceID(deviceID)
        self.maxAssetBytes = maxAssetBytes
        self.now = now
        self.retriesAllowed = retriesAllowed
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
        let recording = PhoneRecording(
            id: id ?? UUID().uuidString,
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
        let known = Set(try store.phoneRecordings().filter { $0.state != .delivered }.map { fileURL($0).standardizedFileURL.path })
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

    /// Saves every `waiting` row that is due (see the type's rules) into
    /// the relay zone as a pending `recording_upload` record with the audio
    /// attached; a successful save flips the row to `uploading`. The first
    /// foreground pass of a process (and the first after
    /// `resendInFlightAfterWipe()`) re-sends due `uploading` rows too — the
    /// relaunch retry: the save upserts the same recordName and the hub's
    /// processed-set absorbs duplicates. Each save counts an attempt. A
    /// transport throw leaves the row for its next due pass; a vanished
    /// local file, or one over the asset cap, fails the row locally (it can
    /// never be sent).
    /// Without a linked device nothing is sent and every row keeps waiting.
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
        // retry armed for the first foreground one.
        let retrying = retriesAllowed()
        let includeInFlight = retrying && resendInFlight
        let ignoreBackoff = includeInFlight && resendIgnoresBackoff
        if includeInFlight {
            resendInFlight = false
            resendIgnoresBackoff = false
        }
        do {
            let rows = try store.phoneRecordings().filter {
                isDue($0, retrying: retrying, includeInFlight: includeInFlight, ignoreBackoff: ignoreBackoff)
            }
            return try await send(rows, deviceID: deviceID)
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

    private func send(_ rows: [PhoneRecording], deviceID: String) async throws -> Int {
        var sent = 0
        for row in rows {
            let file = fileURL(row)
            guard let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64 else {
                try failLocally(row.id, .missingFile)
                continue
            }
            guard size <= maxAssetBytes else {
                try failLocally(row.id, .tooLarge)
                continue
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
            let attemptAt = now()
            // Counted before the save, so an attempt the process dies in
            // still spends its backoff step. A store failure ends the pass.
            try store.recordPhoneRecordingUploadAttempt(id: row.id, at: attemptAt)
            do {
                let record = try CloudRecordFactory.record(
                    for: payload, modifiedAt: attemptAt, assetFileURL: file
                )
                energy?.record(.uploadAttempt)
                try await transport.save([record])
            } catch {
                // Transient (or encoding — unreachable for our own payloads)
                // failure: keep the row for its next due pass.
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

    // MARK: - Echoes (via RelayFeed)

    /// Resolves the ledger from a hub echo. `received` deletes the local
    /// audio (ack-then-delete) and marks the row delivered; `failed` keeps
    /// the file and surfaces the hub's message. Unknown ids are no-ops
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
            try? FileManager.default.removeItem(at: fileURL(row))
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

    /// Removes a ledger row and its local file (the user's delete). The
    /// relay record, if any, is left for the hub's hygiene.
    public func discard(id: String) throws {
        liveCaptureIDs.remove(id)
        try prepareLedger()
        guard let row = try store.phoneRecording(id: id) else { return }
        try store.removePhoneRecording(id: id)
        try? FileManager.default.removeItem(at: fileURL(row))
    }
}

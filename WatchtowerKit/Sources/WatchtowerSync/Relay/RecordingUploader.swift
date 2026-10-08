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
/// - `uploadPending()` at every launch IS the relaunch retry: re-saving the
///   same recordName upserts into the transport's pending queue, and the
///   hub's processed-set absorbs true duplicates.
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
    /// The linked phone's device id, stamped on every upload. nil until
    /// linking finishes (or after an unlink): uploads then wait, because the
    /// hub fails a record without one as `device_not_linked`.
    private var deviceID: String?
    /// Captures this uploader began and has not finished: launch recovery
    /// never touches them, however recovery and a Record tap interleave.
    /// A new process starts empty, so a capture cut short is recovered.
    private var liveCaptureIDs: Set<String> = []
    private var ledgerPrepared = false
    private let logger = Logger(subsystem: "WatchtowerKit", category: "RecordingUploader")

    public init(
        transport: any CloudSyncTransport,
        store: ReplicaStore,
        directory: URL? = nil,
        deviceID: String? = nil,
        maxAssetBytes: Int64 = RecordingUploader.maximumAssetBytes,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.store = store
        self.directory = directory
        self.deviceID = deviceID
        self.maxAssetBytes = maxAssetBytes
        self.now = now
    }

    /// Called by the link flow once the device is linked, and with nil on
    /// unlink. Waiting recordings go out on the next `uploadPending`.
    public func setDeviceID(_ deviceID: String?) {
        self.deviceID = deviceID
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
    private func prepareLedger() throws {
        guard !ledgerPrepared else { return }
        ledgerPrepared = true
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
            failure: nil
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
            failure: nil
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
    @discardableResult
    public func finishCapture(
        id: String,
        endedAt: Date,
        activeDuration: TimeInterval,
        titleHint: String?,
        eventID: String?,
        marks: [Int] = []
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
            eventID: Self.nonBlank(eventID)
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

    /// Deletes every file in the recordings folder that no ledger row
    /// points at (a capture whose row never got written, or a leftover).
    /// Rows are matched by their path resolved against the CURRENT folder.
    /// Runs at launch, after recovery. Returns the deleted files.
    @discardableResult
    public func sweepOrphanFiles() throws -> [URL] {
        guard let directory else { return [] }
        try prepareLedger()
        let known = Set(try store.phoneRecordings().map { fileURL($0).standardizedFileURL.path })
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

    /// Saves every `waiting`/`uploading` row into the relay zone as a pending
    /// `recording_upload` record with the audio attached; a successful save
    /// flips the row to `uploading`. Re-sending an `uploading` row is the
    /// relaunch/push-failure retry — the save upserts the same recordName and
    /// the hub's processed-set absorbs duplicates. A transport throw leaves
    /// the row untouched for the next pass; a vanished local file, or one
    /// over the asset cap, fails the row locally (it can never be sent).
    /// Without a linked device nothing is sent and every row keeps waiting.
    /// Returns how many rows were handed to the transport.
    @discardableResult
    public func uploadPending() async throws -> Int {
        guard let deviceID else {
            logger.notice("recording uploads wait: this phone is not linked")
            return 0
        }
        try prepareLedger()
        let rows = try store.phoneRecordings().filter { $0.state == .waiting || $0.state == .uploading }
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
            do {
                let record = try CloudRecordFactory.record(
                    for: payload, modifiedAt: now(), assetFileURL: file
                )
                try await transport.save([record])
            } catch {
                // Transient (or encoding — unreachable for our own payloads)
                // failure: keep the row for the next uploadPending pass.
                logger.warning("""
                    recording upload save failed for \(row.id, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
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

    /// Flips a `failed` row back to `waiting` and reruns the upload pass.
    /// A local failure (`offersRetry` false) is left as it is.
    public func retryFailed(id: String) async throws {
        guard let row = try store.phoneRecording(id: id), row.offersRetry else { return }
        try store.setPhoneRecordingState(id: id, state: .waiting)
        _ = try await uploadPending()
    }

    /// Removes a ledger row and its local file (the user's delete). The
    /// relay record, if any, is left for the hub's hygiene.
    public func discard(id: String) throws {
        liveCaptureIDs.remove(id)
        guard let row = try store.phoneRecording(id: id) else { return }
        try store.removePhoneRecording(id: id)
        try? FileManager.default.removeItem(at: fileURL(row))
    }
}

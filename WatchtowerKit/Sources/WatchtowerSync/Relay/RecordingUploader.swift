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

    private let transport: any CloudSyncTransport
    private let store: ReplicaStore
    private let maxAssetBytes: Int64
    private let now: @Sendable () -> Date
    /// The linked phone's device id, stamped on every upload. nil until
    /// linking finishes (or after an unlink): uploads then wait, because the
    /// hub fails a record without one as `device_not_linked`.
    private var deviceID: String?
    private let logger = Logger(subsystem: "WatchtowerKit", category: "RecordingUploader")

    public init(
        transport: any CloudSyncTransport,
        store: ReplicaStore,
        deviceID: String? = nil,
        maxAssetBytes: Int64 = RecordingUploader.maximumAssetBytes,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.store = store
        self.deviceID = deviceID
        self.maxAssetBytes = maxAssetBytes
        self.now = now
    }

    /// Called by the link flow once the device is linked, and with nil on
    /// unlink. Waiting recordings go out on the next `uploadPending`.
    public func setDeviceID(_ deviceID: String?) {
        self.deviceID = deviceID
    }

    // MARK: - Register (capture finalized)

    /// Adds a finalized recording to the ledger as `waiting`. Returns nil —
    /// and deletes the file — for degenerate captures: a missing/empty file
    /// or a duration under `minimumDurationSec`. Callers follow up with
    /// `uploadPending()` to hand the new row to the transport.
    ///
    /// - `activeDuration`: the recorded audio length when the capture was
    ///   paused (an interruption or the Pause button); the wall-clock span
    ///   `endedAt - startedAt` is used when nil.
    /// - `eventID`: the calendar event a "Record this meeting" capture
    ///   belongs to; nil (or blank) for a voice note.
    /// - `marks`: mark-moment offsets in seconds of recorded audio, stored
    ///   locally only.
    @discardableResult
    public func register(
        fileURL: URL,
        startedAt: Date,
        endedAt: Date,
        activeDuration: TimeInterval? = nil,
        titleHint: String?,
        eventID: String? = nil,
        marks: [Int] = []
    ) throws -> PhoneRecording? {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        let duration = activeDuration ?? endedAt.timeIntervalSince(startedAt)
        guard size > 0, duration >= Self.minimumDurationSec else {
            try? FileManager.default.removeItem(at: fileURL)
            logger.notice("degenerate recording discarded (size \(size), \(duration, format: .fixed(precision: 2)) s)")
            return nil
        }
        let recording = PhoneRecording(
            id: UUID().uuidString,
            fileURL: fileURL,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSec: Int(duration.rounded()),
            titleHint: Self.nonBlank(titleHint),
            sampleFormat: Self.sampleFormat,
            state: .waiting,
            errorMessage: nil,
            eventID: Self.nonBlank(eventID)
        )
        try store.insertPhoneRecording(recording, marks: marks)
        return recording
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
        let rows = try store.phoneRecordings().filter { $0.state == .waiting || $0.state == .uploading }
        var sent = 0
        for row in rows {
            guard let size = try? FileManager.default.attributesOfItem(atPath: row.fileURL.path)[.size] as? Int64 else {
                try store.setPhoneRecordingState(
                    id: row.id, state: .failed,
                    errorMessage: "The local audio file is missing."
                )
                continue
            }
            guard size <= maxAssetBytes else {
                try store.setPhoneRecordingState(id: row.id, state: .failed, errorMessage: Self.tooLargeMessage)
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
                    for: payload, modifiedAt: now(), assetFileURL: row.fileURL
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
            try? FileManager.default.removeItem(at: row.fileURL)
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
    public func retryFailed(id: String) async throws {
        guard let row = try store.phoneRecording(id: id), row.state == .failed else { return }
        try store.setPhoneRecordingState(id: id, state: .waiting)
        _ = try await uploadPending()
    }

    /// Removes a ledger row and its local file (the user's delete). The
    /// relay record, if any, is left for the hub's hygiene.
    public func discard(id: String) throws {
        guard let row = try store.phoneRecording(id: id) else { return }
        try store.removePhoneRecording(id: id)
        try? FileManager.default.removeItem(at: row.fileURL)
    }
}

import Foundation
import os

/// The seam through which `RelayFeed` hands recording-upload echoes onward —
/// the `ChatChunkAssembling` shape. `RecordingUploader` conforms; the feed is
/// written against the protocol so tests can observe routing directly.
///
/// Delivery contract mirrors chat chunks: the feed calls `applyEcho` for
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

    private let transport: any CloudSyncTransport
    private let store: ReplicaStore
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "WatchtowerKit", category: "RecordingUploader")

    public init(
        transport: any CloudSyncTransport,
        store: ReplicaStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.store = store
        self.now = now
    }

    // MARK: - Register (capture finalized)

    /// Adds a finalized recording to the ledger as `waiting`. Returns nil —
    /// and deletes the file — for degenerate captures: a missing/empty file
    /// or a duration under `minimumDurationSec`. Callers follow up with
    /// `uploadPending()` to hand the new row to the transport.
    @discardableResult
    public func register(
        fileURL: URL,
        startedAt: Date,
        endedAt: Date,
        titleHint: String?
    ) throws -> PhoneRecording? {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        let duration = endedAt.timeIntervalSince(startedAt)
        guard size > 0, duration >= Self.minimumDurationSec else {
            try? FileManager.default.removeItem(at: fileURL)
            logger.notice("degenerate recording discarded (size \(size), \(duration, format: .fixed(precision: 2)) s)")
            return nil
        }
        let trimmedTitle = titleHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let recording = PhoneRecording(
            id: UUID().uuidString,
            fileURL: fileURL,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSec: Int(duration.rounded()),
            titleHint: (trimmedTitle?.isEmpty ?? true) ? nil : trimmedTitle,
            sampleFormat: Self.sampleFormat,
            state: .waiting,
            errorMessage: nil
        )
        try store.insertPhoneRecording(recording)
        return recording
    }

    // MARK: - Upload

    /// Saves every `waiting`/`uploading` row into the relay zone as a pending
    /// `recording_upload` record with the audio attached; a successful save
    /// flips the row to `uploading`. Re-sending an `uploading` row is the
    /// relaunch/push-failure retry — the save upserts the same recordName and
    /// the hub's processed-set absorbs duplicates. A transport throw leaves
    /// the row untouched for the next pass; a vanished local file fails the
    /// row locally (there is nothing left to upload). Returns how many rows
    /// were handed to the transport.
    @discardableResult
    public func uploadPending() async throws -> Int {
        let rows = try store.phoneRecordings().filter { $0.state == .waiting || $0.state == .uploading }
        var sent = 0
        for row in rows {
            guard FileManager.default.fileExists(atPath: row.fileURL.path) else {
                try store.setPhoneRecordingState(
                    id: row.id, state: .failed,
                    errorMessage: "The local audio file is missing."
                )
                continue
            }
            let payload = RecordingUploadPayload(
                id: row.id,
                startedAt: row.startedAt,
                endedAt: row.endedAt,
                durationSec: row.durationSec,
                titleHint: row.titleHint,
                sampleFormat: row.sampleFormat
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

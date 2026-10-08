import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

/// The `recording_job` slice (mobile POC spec §4.12), record name
/// `recording_job-<upload id>`: the Mac-side progress of one phone upload,
/// from the sidecar's `phone_recordings` that `PhoneRecordingJobs` keeps. A
/// fast-lane kind: the tracker nudges it on every change.
///
/// A job is published until 7 days after it ended (`done` or `failed`); an
/// unfinished one stays. At most 100, the latest updated first. The sidecar
/// row itself is kept 31 days, past the `meeting_transcript` window (30
/// days), because its transcript id is that slice's `phone_recording_id`.
/// `error` is cut at 300 with `…`; the Kit mirror has no `_clipped` flag.
struct RecordingJobSlice: SliceSource {
    let kind = SliceKind.recordingJob

    static let keptAfterEnd: TimeInterval = 7 * 86_400
    static let maxRecords = 100
    static let maxError = 300
    static let sidecarRetention: TimeInterval = 31 * 86_400

    let sidecar: HubSyncState
    let now: @Sendable () -> Date
    private static let logger = Logger(subsystem: Constants.bundleID, category: "RecordingJobSlice")

    init(sidecar: HubSyncState, now: @escaping @Sendable () -> Date = { Date() }) {
        self.sidecar = sidecar
        self.now = now
    }

    struct Payload: Encodable, Equatable {
        let id: String
        let status: String
        let percent: Int?
        let transcriptID: Int64?
        let error: String?
        let updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id, status, percent
            case transcriptID = "transcript_id"
            case error, updatedAt
        }
    }

    /// Reads the sidecar, not `db`: the jobs are the hub's own state.
    func records(_ db: Database) throws -> [SliceRecord] {
        let stamp = now()
        do {
            try sidecar.prunePhoneRecordings(olderThan: stamp.addingTimeInterval(-Self.sidecarRetention))
        } catch {
            // Housekeeping only: the jobs still publish, and the next tick prunes.
            Self.logger.warning("phone recording prune failed: \(error.localizedDescription, privacy: .public)")
        }
        let shown = try sidecar.phoneRecordings().filter {
            !$0.status.isFinished || stamp.timeIntervalSince($0.updatedAt) <= Self.keptAfterEnd
        }
        let encoder = RelayCoder.makeEncoder()
        return try shown.prefix(Self.maxRecords).map { job in
            // Whole seconds, like every other Unix-second stamp on the wire.
            let updatedAt = Date(timeIntervalSince1970: job.updatedAt.timeIntervalSince1970.rounded(.down))
            let payload = Payload(
                id: job.uploadID,
                status: job.status.rawValue,
                percent: job.status == .transcribing ? job.percent : nil,
                transcriptID: job.status == .done ? job.transcriptID : nil,
                error: job.status == .failed ? job.error.map { SliceClip.text($0, limit: Self.maxError).text } : nil,
                updatedAt: updatedAt
            )
            return SliceRecord(kind: kind, id: job.uploadID, modifiedAt: updatedAt, payload: try encoder.encode(payload))
        }
    }
}

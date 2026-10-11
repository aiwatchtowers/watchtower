import Foundation
import WatchtowerSync

/// Where the Mac is with one phone recording (spec §4.12). rawValues are
/// wire format — never rename.
public enum RecordingJobStatus: String, Codable, CaseIterable, Sendable {
    /// The hub ingested the upload.
    case received
    /// Waiting for the transcription engine (for example, behind a capture).
    case queued
    case transcribing
    case diarizing
    case summarizing
    case done
    case failed

    /// A status this build does not know decodes as `queued`, so a newer
    /// Mac's phase never fails the whole record.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .queued
    }
}

/// The `recording_job` DataZone slice (mobile POC spec §4.12), record name
/// `recording_job-<upload id>`: the Mac-side progress of one phone upload.
/// A fast-lane kind, kept 7 days after `done` or `failed`.
///
/// Wire: `RelayCoder` JSON (snake_case, Unix-second dates, sorted keys). A
/// nil optional is an absent key.
public struct RecordingJob: Codable, Identifiable, Equatable, Sendable {
    /// The phone's recording upload id (`RecordingUploadPayload.id`).
    public let id: String
    public let status: RecordingJobStatus
    /// 0–100, present only while `transcribing`.
    public let percent: Int?
    /// The transcript, once `done`.
    public let transcriptID: Int?
    /// At most 300, on `failed`.
    public let error: String?
    public let updatedAt: Date

    public var recordName: String { SliceKind.recordingJob.recordName(id: id) }

    // convertFromSnakeCase maps "transcript_id" -> "transcriptId"
    // (lowercase d), so that key's stringValue uses this form.
    enum CodingKeys: String, CodingKey {
        case id, status, percent
        case transcriptID = "transcriptId"
        case error, updatedAt
    }

    public init(
        id: String,
        status: RecordingJobStatus,
        percent: Int? = nil,
        transcriptID: Int? = nil,
        error: String? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.status = status
        self.percent = percent
        self.transcriptID = transcriptID
        self.error = error
        self.updatedAt = updatedAt
    }
}

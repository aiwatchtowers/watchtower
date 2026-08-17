import Foundation
import GRDB

// MARK: - Phone recordings (local capture → relay upload ledger)

/// One locally captured recording and where it stands on its way to the Mac.
/// The audio file itself lives on disk at `fileURL`; this row is the durable
/// upload ledger (`RecordingUploader` is the only writer).
public struct PhoneRecording: Equatable, Identifiable, Sendable {
    public enum State: String, Sendable {
        /// Finalized locally, not yet handed to the transport.
        case waiting
        /// Saved into the relay zone (the transport uploads it in the
        /// background); awaiting the hub's ack.
        case uploading
        /// The Mac acknowledged receipt — the local file is deleted and the
        /// transcript will arrive via the meeting_transcript slice.
        case delivered
        /// The hub rejected the upload (see `errorMessage`); retriable.
        case failed
    }

    public let id: String
    public let fileURL: URL
    public let startedAt: Date
    public let endedAt: Date
    public let durationSec: Int
    public let titleHint: String?
    public let sampleFormat: String
    public let state: State
    public let errorMessage: String?
}

extension ReplicaStore {
    /// All ledger rows, newest first (started_at DESC, id for stability).
    public func phoneRecordings() throws -> [PhoneRecording] {
        try writer.read { db in try phoneRecordings(from: db) }
    }

    /// `phoneRecordings()` against an ALREADY-OPEN database — for the app's
    /// ValueObservation tracking closures (same reentrancy rule as
    /// `pendingActions(from:)`).
    public func phoneRecordings(from db: Database) throws -> [PhoneRecording] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM phone_recordings ORDER BY started_at DESC, recording_id"
        )
        return rows.compactMap { row in
            guard let state = PhoneRecording.State(rawValue: row["state"]) else { return nil }
            return PhoneRecording(
                id: row["recording_id"],
                fileURL: URL(fileURLWithPath: row["file_path"]),
                startedAt: Date(timeIntervalSince1970: row["started_at"]),
                endedAt: Date(timeIntervalSince1970: row["ended_at"]),
                durationSec: row["duration_sec"],
                titleHint: row["title_hint"],
                sampleFormat: row["sample_format"],
                state: state,
                errorMessage: row["error_message"]
            )
        }
    }

    func insertPhoneRecording(_ recording: PhoneRecording) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO phone_recordings
                        (recording_id, file_path, started_at, ended_at, duration_sec,
                         title_hint, sample_format, state, error_message)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    recording.id, recording.fileURL.path,
                    recording.startedAt.timeIntervalSince1970,
                    recording.endedAt.timeIntervalSince1970,
                    recording.durationSec, recording.titleHint,
                    recording.sampleFormat, recording.state.rawValue,
                    recording.errorMessage
                ]
            )
        }
    }

    /// Unknown ids are a no-op (the ack-after-delete degenerate branch).
    func setPhoneRecordingState(
        id: String,
        state: PhoneRecording.State,
        errorMessage: String? = nil
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE phone_recordings SET state = ?, error_message = ? WHERE recording_id = ?",
                arguments: [state.rawValue, errorMessage, id]
            )
        }
    }

    func phoneRecording(id: String) throws -> PhoneRecording? {
        try writer.read { db in
            try phoneRecordings(from: db).first { $0.id == id }
        }
    }

    /// Removes one ledger row (the phone's "Remove" affordance on delivered/
    /// failed rows). The audio file is the caller's to delete.
    public func removePhoneRecording(id: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM phone_recordings WHERE recording_id = ?",
                arguments: [id]
            )
        }
    }
}

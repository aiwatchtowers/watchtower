import Foundation
import GRDB

// MARK: - Phone recordings (local capture → relay upload ledger)

/// One locally captured recording and where it stands on its way to the Mac.
/// The audio file itself lives on disk (`fileURL(in:)`); this row is the
/// durable upload ledger (`RecordingUploader` is the only writer).
public struct PhoneRecording: Equatable, Identifiable, Sendable {
    /// A failure on the phone itself that a retry can only repeat. nil on a
    /// failure the Mac or the network caused, which offers Retry.
    public enum LocalFailure: String, Sendable {
        case missingFile = "missing_file"
        case tooLarge = "too_large"
        case unrecoverable
    }

    public enum State: String, Sendable {
        /// The capture is still being written. A row left in this state at
        /// launch belongs to a capture cut short (kill, jetsam, crash) and is
        /// finalized from its file.
        case recording
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
    /// The file's name inside the recordings folder, or an absolute path for
    /// a file kept elsewhere. Stored relative because iOS may move the app's
    /// container between launches (an app update does).
    public let storedPath: String
    public let startedAt: Date
    public let endedAt: Date
    public let durationSec: Int
    public let titleHint: String?
    public let sampleFormat: String
    public let state: State
    public let errorMessage: String?
    /// The calendar event the recording was started from; nil for a
    /// "No meeting" voice note (spec §5.3).
    public let eventID: String?

    /// Set with a `failed` state for a local failure; nil otherwise.
    public let failure: LocalFailure?

    /// Retry is offered for a failure the Mac or the network caused. A local
    /// failure that a retry can only repeat (the file is gone, too large,
    /// or not recoverable) offers none.
    public var offersRetry: Bool {
        state == .failed && failure == nil
    }

    /// The audio file, resolved against the CURRENT recordings folder.
    public func fileURL(in directory: URL?) -> URL {
        if let directory, !storedPath.hasPrefix("/") {
            return directory.appendingPathComponent(storedPath)
        }
        return URL(fileURLWithPath: storedPath)
    }
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
                storedPath: row["file_path"],
                startedAt: Date(timeIntervalSince1970: row["started_at"]),
                endedAt: Date(timeIntervalSince1970: row["ended_at"]),
                durationSec: row["duration_sec"],
                titleHint: row["title_hint"],
                sampleFormat: row["sample_format"],
                state: state,
                errorMessage: row["error_message"],
                eventID: row["event_id"],
                failure: (row["failure_kind"] as String?).flatMap(PhoneRecording.LocalFailure.init(rawValue:))
            )
        }
    }

    /// Inserts one ledger row and its mark-moment offsets in a single
    /// transaction. Duplicate offsets collapse to one mark.
    func insertPhoneRecording(_ recording: PhoneRecording, marks: [Int] = []) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO phone_recordings
                        (recording_id, file_path, started_at, ended_at, duration_sec,
                         title_hint, sample_format, state, error_message, event_id, failure_kind)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    recording.id, recording.storedPath,
                    recording.startedAt.timeIntervalSince1970,
                    recording.endedAt.timeIntervalSince1970,
                    recording.durationSec, recording.titleHint,
                    recording.sampleFormat, recording.state.rawValue,
                    recording.errorMessage, recording.eventID, recording.failure?.rawValue
                ]
            )
            for offset in marks where offset >= 0 {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO phone_recording_marks (recording_id, offset_sec) VALUES (?, ?)",
                    arguments: [recording.id, offset]
                )
            }
        }
    }

    /// The recording's mark-moment offsets in seconds of recorded audio,
    /// ascending. They stay on the phone (jump points in the transcript
    /// view) and never travel in the upload payload (spec §5.3).
    public func phoneRecordingMarks(id: String) throws -> [Int] {
        try writer.read { db in try phoneRecordingMarks(id: id, from: db) }
    }

    /// `phoneRecordingMarks(id:)` against an ALREADY-OPEN database (for
    /// ValueObservation tracking closures).
    public func phoneRecordingMarks(id: String, from db: Database) throws -> [Int] {
        try Int.fetchAll(
            db,
            sql: "SELECT offset_sec FROM phone_recording_marks WHERE recording_id = ? ORDER BY offset_sec",
            arguments: [id]
        )
    }

    /// Adds one mark-moment offset (a duplicate is ignored). Written as the
    /// owner taps, so marks survive a capture cut short.
    func insertPhoneRecordingMark(id: String, offsetSec: Int) throws {
        guard offsetSec >= 0 else { return }
        try writer.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO phone_recording_marks (recording_id, offset_sec) VALUES (?, ?)",
                arguments: [id, offsetSec]
            )
        }
    }

    /// Turns a `recording` row into a finalized `waiting` one.
    func finalizePhoneRecording(
        id: String,
        endedAt: Date,
        durationSec: Int,
        titleHint: String?,
        eventID: String?
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE phone_recordings
                    SET state = 'waiting', ended_at = ?, duration_sec = ?, title_hint = ?, event_id = ?,
                        error_message = NULL, failure_kind = NULL
                    WHERE recording_id = ?
                    """,
                arguments: [endedAt.timeIntervalSince1970, durationSec, titleHint, eventID, id]
            )
        }
    }

    /// Unknown ids are a no-op (the ack-after-delete degenerate branch).
    /// `failure` is stored with a `failed` state and cleared otherwise.
    func setPhoneRecordingState(
        id: String,
        state: PhoneRecording.State,
        errorMessage: String? = nil,
        failure: PhoneRecording.LocalFailure? = nil
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE phone_recordings SET state = ?, error_message = ?, failure_kind = ? WHERE recording_id = ?",
                arguments: [state.rawValue, errorMessage, failure?.rawValue, id]
            )
        }
    }

    /// Rewrites where a row's file is (the move to a relative name).
    func setPhoneRecordingPath(id: String, storedPath: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE phone_recordings SET file_path = ? WHERE recording_id = ?",
                arguments: [storedPath, id]
            )
        }
    }

    /// One ledger row; nil for an unknown id.
    public func phoneRecording(id: String) throws -> PhoneRecording? {
        try writer.read { db in
            try phoneRecordings(from: db).first { $0.id == id }
        }
    }

    /// Removes one ledger row (the phone's "Remove" affordance on delivered/
    /// failed rows) and, by cascade, its marks. The audio file is the
    /// caller's to delete.
    public func removePhoneRecording(id: String) throws {
        try writer.write { db in
            // Explicit as well as the FK cascade, so a connection opened
            // without foreign keys never leaves orphan marks.
            try db.execute(sql: "DELETE FROM phone_recording_marks WHERE recording_id = ?", arguments: [id])
            try db.execute(
                sql: "DELETE FROM phone_recordings WHERE recording_id = ?",
                arguments: [id]
            )
        }
    }
}

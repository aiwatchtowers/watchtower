import Foundation
import GRDB

/// A recording not yet saved as a transcript: one `pending_transcripts` row
/// (migration 00157, #604 S3/S4; it replaced the `rec_*.meta`/`.txt`/`.json`
/// sidecars). `transcript` and `metaJSON` are nil until transcription
/// succeeded (then a failed save retries from them); `metaJSON` is
/// `PersistedTranscriptMeta`'s encoding.
package struct PendingTranscript: Equatable, Sendable {
    package let recording: String
    package let eventID: String?
    package let title: String?
    package let transcript: String?
    package let metaJSON: String?
    package let startedAt: Date
    package let transcribedAt: Date?
    /// The recording saves private (`--private`, MEETPRIV-01).
    package let isPrivate: Bool
    /// The owner dismissed the recovered recording: kept as a tombstone so the
    /// audio file (which stays until the daemon's orphan sweep) is not offered
    /// again. Stored as `meta_json = '{"dismissed":true}'`.
    package var dismissed: Bool { metaJSON == PendingTranscriptQueries.dismissedMeta }
}

/// `pending_transcripts`. The Desktop is the only writer; Go never reads it.
package enum PendingTranscriptQueries {
    package static let dismissedMeta = #"{"dismissed":true}"#

    /// A recording starts (or a legacy pointer or sidecar is imported): its
    /// event link, title and private flag. An existing row of the recording
    /// keeps its kept transcript (a legacy import may bring the transcript
    /// first).
    package static func begin(
        _ db: Database, recording: String, eventID: String?, title: String?, isPrivate: Bool = false, at: Date
    ) throws {
        try db.execute(sql: """
            INSERT INTO pending_transcripts (recording, event_id, title, private, started_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(recording) DO UPDATE SET event_id = excluded.event_id, title = excluded.title,
                private = excluded.private
            """, arguments: [recording, eventID, title, isPrivate, at.timeIntervalSince1970])
    }

    /// The owner flipped the flag on a recording still capturing or queued.
    package static func setPrivate(_ db: Database, recording: String, _ isPrivate: Bool) throws {
        try db.execute(sql: "UPDATE pending_transcripts SET private = ? WHERE recording = ?",
                       arguments: [isPrivate, recording])
    }

    /// Reserves `recording` (a phone recording's name): false when a row
    /// already holds it, so the caller tries the next name.
    package static func reserve(
        _ db: Database, recording: String, eventID: String?, title: String?, isPrivate: Bool = false, at: Date
    ) throws -> Bool {
        try db.execute(sql: """
            INSERT INTO pending_transcripts (recording, event_id, title, private, started_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(recording) DO NOTHING
            """, arguments: [recording, eventID, title, isPrivate, at.timeIntervalSince1970])
        return db.changesCount > 0
    }

    /// Transcription succeeded: a failed save retries from this text.
    package static func saveTranscript(_ db: Database, recording: String, text: String, metaJSON: String, at: Date)
        throws {
        try db.execute(sql: """
            INSERT INTO pending_transcripts (recording, transcript, meta_json, started_at, transcribed_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(recording) DO UPDATE SET transcript = excluded.transcript, meta_json = excluded.meta_json,
                transcribed_at = excluded.transcribed_at
            """, arguments: [recording, text, metaJSON, at.timeIntervalSince1970, at.timeIntervalSince1970])
    }

    /// Forgets a persisted transcript (an explicit re-transcribe), keeping
    /// the recording pending.
    package static func clearTranscript(_ db: Database, recording: String) throws {
        try db.execute(sql: """
            UPDATE pending_transcripts SET transcript = NULL, meta_json = NULL, transcribed_at = NULL
            WHERE recording = ?
            """, arguments: [recording])
    }

    /// Marks a recovered recording dismissed (see `PendingTranscript.dismissed`),
    /// writing the row when it had none (an audio-only recovery).
    package static func dismiss(_ db: Database, recording: String, at: Date) throws {
        try db.execute(sql: """
            INSERT INTO pending_transcripts (recording, meta_json, started_at) VALUES (?, ?, ?)
            ON CONFLICT(recording) DO UPDATE SET transcript = NULL, meta_json = excluded.meta_json,
                transcribed_at = NULL
            """, arguments: [recording, dismissedMeta, at.timeIntervalSince1970])
    }

    package static func remove(_ db: Database, recording: String) throws {
        try db.execute(sql: "DELETE FROM pending_transcripts WHERE recording = ?", arguments: [recording])
    }

    package static func row(_ db: Database, recording: String) throws -> PendingTranscript? {
        try Row.fetchOne(db, sql: "SELECT * FROM pending_transcripts WHERE recording = ?", arguments: [recording])
            .map(decode)
    }

    /// Every row, oldest first.
    package static func all(_ db: Database) throws -> [PendingTranscript] {
        try Row.fetchAll(db, sql: "SELECT * FROM pending_transcripts ORDER BY started_at, recording").map(decode)
    }

    /// The audio paths saved transcripts point at: a `rec_*` file there was
    /// saved, not lost.
    package static func savedAudioPaths(_ db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT audio_path FROM meeting_transcripts WHERE audio_path IS NOT NULL"))
    }

    private static func decode(_ row: Row) -> PendingTranscript {
        PendingTranscript(
            recording: row["recording"], eventID: row["event_id"], title: row["title"],
            transcript: row["transcript"], metaJSON: row["meta_json"],
            startedAt: Date(timeIntervalSince1970: row["started_at"]),
            transcribedAt: (row["transcribed_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            isPrivate: row["private"])
    }
}

import CryptoKit
import Foundation
import GRDB

extension MeetingTranscriptSlice {
    // MARK: - Window

    struct TranscriptRow {
        let id: Int64
        let eventID: String?
        let title: String
        let durationSec: Int
        let segmentsJSON: String?
        /// `transcript_text`, read only when `segments_json` is NULL or not
        /// valid JSON (the legacy fallback).
        let legacyText: String?
        /// The big columns' lengths, as `lightKeys` reads them.
        let lengths: [Int?]
        let summaryJSON: String?
        let chaptersJSON: String?
        let createdAt: String
        let updatedAt: String
    }

    /// The window's transcripts, newest first: id and event id only.
    static func window(_ db: Database, now: Date, calendar: Calendar) throws -> [(id: Int64, eventID: String?)] {
        let since = SliceDate.stamp(now.addingTimeInterval(-Double(windowDays) * 86_400))
        let eventIDs = Array(try CalendarEventSlice.windowEventIDs(db, now: now, calendar: calendar))
        let eventClause = eventIDs.isEmpty ? "" : " OR event_id IN (\(placeholders(eventIDs.count)))"
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, event_id FROM meeting_transcripts
            WHERE created_at >= ?\(eventClause)
            ORDER BY created_at DESC, id DESC
            LIMIT \(maxTranscripts)
            """, arguments: StatementArguments([since] + eventIDs))
        return rows.map { (id: $0["id"], eventID: $0["event_id"]) }
    }

    /// What the light key covers: every column the record is derived from,
    /// the big ones by their length only. A writer that changes a big
    /// column bumps `updated_at` (Go's `SetMeetingTranscript*` and the
    /// Desktop's `MeetingTranscriptQueries`), and a same-second rewrite of
    /// the same length is caught by `settleTime`.
    struct LightKey {
        let id: Int64
        let eventID: String?
        let title: String
        let durationSec: Int
        let createdAt: String
        let updatedAt: String
        let lengths: [Int?]

        init(id: Int64, eventID: String?, title: String, durationSec: Int, createdAt: String, updatedAt: String, lengths: [Int?]) {
            self.id = id
            self.eventID = eventID
            self.title = title
            self.durationSec = durationSec
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.lengths = lengths
        }

        /// The same key from a full row.
        init(_ row: TranscriptRow) {
            self.init(
                id: row.id, eventID: row.eventID, title: row.title, durationSec: row.durationSec,
                createdAt: row.createdAt, updatedAt: row.updatedAt, lengths: row.lengths
            )
        }
    }

    /// The big columns' byte lengths, in `LightKey.lengths`' order.
    /// `octet_length` (SQLite 3.43+) reads a text's size from its record
    /// header without loading the text itself; NULL stays NULL.
    static let lengthColumns = """
        octet_length(segments_json) AS segments_length, octet_length(transcript_text) AS text_length,
        octet_length(summary_json) AS summary_length, octet_length(chapters_json) AS chapters_length
        """

    static func lengths(_ row: Row) -> [Int?] {
        [row["segments_length"], row["text_length"], row["summary_length"], row["chapters_length"]]
    }

    /// The window rows' light keys: no big column leaves SQLite.
    static func lightKeys(_ db: Database, ids: [Int64]) throws -> [LightKey] {
        guard !ids.isEmpty else { return [] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, event_id, title, duration_sec, created_at, updated_at, \(lengthColumns)
            FROM meeting_transcripts
            WHERE id IN (\(placeholders(ids.count)))
            """, arguments: StatementArguments(ids))
        return rows.map { row in
            LightKey(
                id: row["id"], eventID: row["event_id"], title: row["title"], durationSec: row["duration_sec"],
                createdAt: row["created_at"], updatedAt: row["updated_at"], lengths: lengths(row)
            )
        }
    }

    static func lightFingerprint(_ key: LightKey, recaps: [RecapRef], phone: String?) -> Data {
        digest([
            String(key.id), key.eventID, key.title, String(key.durationSec), key.createdAt, key.updatedAt
        ] + key.lengths.map { $0.map(String.init) } + recapFields(recaps) + [phone])
    }

    /// The candidate recaps as fingerprint fields: their count, then each
    /// one's id and `updated_at`. Any candidate's change (not only the
    /// chosen one's: which one is readable is known only once decoded)
    /// rebuilds the row.
    static func recapFields(_ recaps: [RecapRef]) -> [String?] {
        [String(recaps.count)] + recaps.flatMap { [String($0.id), $0.updatedAt] }
    }

    /// The columns the projection reads, in the window's order.
    static func rows(_ db: Database, ids: [Int64]) throws -> [TranscriptRow] {
        guard !ids.isEmpty else { return [] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, event_id, title, duration_sec, segments_json, summary_json, chapters_json, created_at, updated_at,
                   CASE WHEN segments_json IS NULL OR NOT json_valid(segments_json) THEN transcript_text END AS legacy_text,
                   \(lengthColumns)
            FROM meeting_transcripts
            WHERE id IN (\(placeholders(ids.count)))
            ORDER BY created_at DESC, id DESC
            """, arguments: StatementArguments(ids))
        return rows.map { row in
            TranscriptRow(
                id: row["id"],
                eventID: row["event_id"],
                title: row["title"],
                durationSec: row["duration_sec"],
                segmentsJSON: row["segments_json"],
                legacyText: row["legacy_text"],
                lengths: lengths(row),
                summaryJSON: row["summary_json"],
                chaptersJSON: row["chapters_json"],
                createdAt: row["created_at"],
                updatedAt: row["updated_at"]
            )
        }
    }

    /// SHA-256 over everything the record is derived from; each field is
    /// tagged (nil vs present) and length-prefixed, so no two inputs collide.
    static func fingerprint(_ row: TranscriptRow, recaps: [RecapRef], phone: String?) -> Data {
        digest([
            String(row.id), row.eventID, row.title, String(row.durationSec), row.createdAt, row.updatedAt,
            row.segmentsJSON, row.legacyText, row.summaryJSON, row.chaptersJSON
        ] + recapFields(recaps) + [phone])
    }

    /// SHA-256 over `fields`, each tagged (nil vs present) and
    /// length-prefixed.
    static func digest(_ fields: [String?]) -> Data {
        var hasher = SHA256()
        for field in fields {
            guard let field else {
                hasher.update(data: Data([0]))
                continue
            }
            let bytes = Data(field.utf8)
            let length = withUnsafeBytes(of: UInt64(bytes.count).littleEndian) { Data($0) }
            hasher.update(data: Data([1]) + length)
            hasher.update(data: bytes)
        }
        return Data(hasher.finalize())
    }

    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}

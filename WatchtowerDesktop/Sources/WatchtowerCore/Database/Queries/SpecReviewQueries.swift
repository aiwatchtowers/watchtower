import Foundation
import GRDB

/// `spec_reviews` (read) and `spec_review_marks` (the owner's marks, written
/// here). Marks of an unknown state are left out, so a newer build's value
/// never blanks the screen.
package enum SpecReviewQueries {
    package static func row(_ db: Database, askID: Int64) throws -> SpecReviewRow? {
        try SpecReviewRow.fetchOne(db, sql: "SELECT * FROM spec_reviews WHERE ask_id = ?", arguments: [askID])
    }

    package static func marks(_ db: Database, askID: Int64) throws -> [String: SpecReviewMark] {
        var out: [String: SpecReviewMark] = [:]
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT item_key, state, body FROM spec_review_marks WHERE ask_id = ?",
            arguments: [askID]
        )
        for row in rows {
            let key: String = row["item_key"]
            let raw: String = row["state"]
            guard let state = SpecReviewMarkState(rawValue: raw) else { continue }
            out[key] = SpecReviewMark(key: key, state: state, body: row["body"])
        }
        return out
    }

    package static func setMark(_ db: Database, askID: Int64, mark: SpecReviewMark, now: Date) throws {
        try db.execute(
            sql: """
                INSERT INTO spec_review_marks (ask_id, item_key, state, body, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(ask_id, item_key) DO UPDATE SET
                    state = excluded.state, body = excluded.body, updated_at = excluded.updated_at
                """,
            arguments: [askID, mark.key, mark.state.rawValue, mark.body, timestamp(now)]
        )
    }

    package static func clearMark(_ db: Database, askID: Int64, key: String) throws {
        try db.execute(
            sql: "DELETE FROM spec_review_marks WHERE ask_id = ? AND item_key = ?",
            arguments: [askID, key]
        )
    }

    /// UTC `yyyy-MM-ddTHH:mm:ssZ`, the form Go writes.
    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

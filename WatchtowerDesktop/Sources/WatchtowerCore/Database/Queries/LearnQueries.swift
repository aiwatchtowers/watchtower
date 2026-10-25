import Foundation
import GRDB

/// The Learn zone's database side: the seen rows (written only here, design
/// §9.6) and the signals that read a table row.
package enum LearnQueries {
    /// Tables the reads use, for a ValueObservation region.
    package static let observedTables = [
        "learn_seen", "meeting_transcripts", "chat_messages", "projects", "reaction_commands", "automations"
    ]

    /// Every seen row by id; a `how` this build does not know is skipped.
    package static func fetchSeen(_ db: Database) throws -> [String: LearnSeenHow] {
        let rows = try Row.fetchAll(db, sql: "SELECT item_id, how FROM learn_seen")
        var seen: [String: LearnSeenHow] = [:]
        for row in rows {
            guard let how = LearnSeenHow(rawValue: row["how"]) else { continue }
            seen[row["item_id"]] = how
        }
        return seen
    }

    /// Records the cards as seen; a card already seen keeps its first row.
    package static func markSeen(_ db: Database, ids: [String], how: LearnSeenHow, now: Date) throws {
        let seenAt = timestamp(now)
        for id in ids {
            try db.execute(
                sql: "INSERT OR IGNORE INTO learn_seen (item_id, how, seen_at) VALUES (?, ?, ?)",
                arguments: [id, how.rawValue, seenAt])
        }
    }

    /// Show again: the card is unseen until the next Got it, action or use.
    package static func showAgain(_ db: Database, id: String) throws {
        try db.execute(sql: "DELETE FROM learn_seen WHERE item_id = ?", arguments: [id])
    }

    /// The row-backed signals, in one read. The others (memory, sources, the
    /// phone, dictation) come from state the app already holds.
    package static func rowSignals(_ db: Database) throws -> Set<LearnSignal> {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT
              EXISTS (SELECT 1 FROM meeting_transcripts) AS meeting,
              EXISTS (SELECT 1 FROM chat_messages WHERE role = 'user') AS chat,
              EXISTS (SELECT 1 FROM projects) AS workbench,
              EXISTS (SELECT 1 FROM reaction_commands) AS reaction,
              EXISTS (SELECT 1 FROM automations WHERE origin = 'owner') AS automation
            """)
        else { return [] }
        let columns: [(String, LearnSignal)] = [
            ("meeting", .meetingRecorded), ("chat", .chatUsed), ("workbench", .workbenchBound),
            ("reaction", .reactionUsed), ("automation", .automationCreated)
        ]
        return Set(columns.compactMap { column, signal in (row[column] as Bool) ? signal : nil })
    }

    /// UTC ISO-8601 seconds (`2026-10-25T09:30:00Z`), the `seen_at` format.
    static func timestamp(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }
}

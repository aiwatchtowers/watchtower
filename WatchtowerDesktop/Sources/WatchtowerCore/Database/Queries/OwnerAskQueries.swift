import Foundation
import GRDB

package enum AskAnswerError: LocalizedError, Equatable {
    /// The ask is no longer open: the agent withdrew or superseded it (or it
    /// was answered) since the owner opened it. Nothing was written.
    case notOpen

    package var errorDescription: String? {
        switch self {
        case .notOpen: "The agent withdrew this ask meanwhile — your answer was not sent."
        }
    }
}

/// A list of asks read row by row: a row `OwnerAsk(row:)` refuses (a payload
/// or answer this app cannot read, e.g. after Go relaxed a card bound) is
/// left out and named, so it never blanks the others — the way `targetAsks`
/// and the notification snapshot read raw rows.
package struct OwnerAskRows: Equatable, Sendable {
    package var asks: [OwnerAsk]
    /// The ids of the rows that could not be read, in list order.
    package var unreadableIDs: [Int64]

    package init(asks: [OwnerAsk] = [], unreadableIDs: [Int64] = []) {
        self.asks = asks
        self.unreadableIDs = unreadableIDs
    }

    /// "1 ask could not be read (#12)." — nil when every row was read.
    package var problem: String? {
        guard !unreadableIDs.isEmpty else { return nil }
        let count = unreadableIDs.count
        let ids = unreadableIDs.map { "#\($0)" }.joined(separator: ", ")
        return "\(count) \(count == 1 ? "ask" : "asks") could not be read (\(ids))."
    }

    static func fetch(_ db: Database, sql: String, arguments: StatementArguments) throws -> Self {
        var out = Self()
        for row in try Row.fetchAll(db, sql: sql, arguments: arguments) {
            do {
                out.asks.append(try OwnerAsk(row: row))
            } catch {
                out.unreadableIDs.append(row["id"])
            }
        }
        return out
    }
}

/// Owner asks (spec 2026-10-03 Parts 2 and 8). Go writes `open`, `withdrawn`
/// and `delivered`; the Desktop's only write is `open → answered` with the
/// answer, guarded on `status = 'open'` (`answer`).
package enum OwnerAskQueries {
    /// The workbench's open asks, oldest first, read row by row.
    package static func openAsks(_ db: Database, projectID: Int64) throws -> OwnerAskRows {
        try OwnerAskRows.fetch(
            db,
            sql: "SELECT * FROM owner_asks WHERE project_id = ? AND status = 'open' ORDER BY created_at, id",
            arguments: [projectID]
        )
    }

    /// A session's answered, delivered and withdrawn asks, newest first, read
    /// row by row. A nil session lists the workbench's asks filed from
    /// outside the app.
    package static func closedAsks(_ db: Database, projectID: Int64, sessionID: Int64?) throws -> OwnerAskRows {
        try OwnerAskRows.fetch(
            db,
            sql: """
                SELECT * FROM owner_asks
                WHERE project_id = ? AND session_id IS ? AND status != 'open'
                ORDER BY created_at DESC, id DESC
                """,
            arguments: [projectID, sessionID]
        )
    }

    /// One ask of `projectID` whatever its status; nil when there is none.
    package static func ask(_ db: Database, id: Int64, projectID: Int64) throws -> OwnerAsk? {
        try OwnerAsk.fetchOne(
            db,
            sql: "SELECT * FROM owner_asks WHERE id = ? AND project_id = ?",
            arguments: [id, projectID]
        )
    }

    /// How many answered, delivered and withdrawn asks each session of the
    /// workbench has; the nil key counts the asks filed from outside the app.
    package static func closedCounts(_ db: Database, projectID: Int64) throws -> [Int64?: Int] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT session_id, COUNT(*) FROM owner_asks WHERE project_id = ? AND status != 'open' GROUP BY session_id",
            arguments: [projectID]
        )
        var counts: [Int64?: Int] = [:]
        for row in rows { counts[row[0] as Int64?] = row[1] }
        return counts
    }

    /// A superseded ask's id → the id of the round that replaced it (the ask
    /// whose `previous_ask_id` names it).
    package static func replacements(_ db: Database, projectID: Int64) throws -> [Int64: Int64] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT previous_ask_id, id FROM owner_asks WHERE project_id = ? AND previous_ask_id IS NOT NULL",
            arguments: [projectID]
        )
        var replaced: [Int64: Int64] = [:]
        for row in rows { replaced[row[0]] = row[1] }
        return replaced
    }

    /// A board target's asks, newest first, for its detail card. Read as
    /// list items, so one undecodable payload never hides the others.
    package static func targetAsks(_ db: Database, projectID: Int64, targetID: Int64) throws -> [OwnerAskListItem] {
        try OwnerAskListItem.fetchAll(
            db,
            sql: """
                SELECT id, title, status, withdrawn_reason FROM owner_asks
                WHERE project_id = ? AND target_id = ?
                ORDER BY created_at DESC, id DESC
                """,
            arguments: [projectID, targetID]
        )
    }

    /// Answers an open ask of `projectID` in one guarded write. Zero rows
    /// changed — withdrawn, superseded or already answered meanwhile, or not
    /// this workbench's — throws `.notOpen` and writes nothing.
    package static func answer(
        _ db: Database,
        askID: Int64,
        projectID: Int64,
        with answer: OwnerAskAnswer,
        at date: Date = Date()
    ) throws {
        try db.execute(
            sql: """
                UPDATE owner_asks SET status = 'answered', answer = ?, answered_at = ?
                WHERE id = ? AND project_id = ? AND status = 'open'
                """,
            arguments: [try answer.encoded(), timestamp(date), askID, projectID]
        )
        if db.changesCount == 0 { throw AskAnswerError.notOpen }
    }

    /// UTC `yyyy-MM-ddTHH:mm:ssZ`, the form of `created_at`.
    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

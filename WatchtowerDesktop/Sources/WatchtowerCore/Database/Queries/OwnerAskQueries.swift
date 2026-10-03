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

/// Owner asks (spec 2026-10-03 Parts 2 and 8). Go writes `open`, `withdrawn`
/// and `delivered`; the Desktop's only write is `open → answered` with the
/// answer, guarded on `status = 'open'` (`answer`).
package enum OwnerAskQueries {
    /// The workbench's open asks, oldest first.
    package static func openAsks(_ db: Database, projectID: Int64) throws -> [OwnerAsk] {
        try OwnerAsk.fetchAll(
            db,
            sql: "SELECT * FROM owner_asks WHERE project_id = ? AND status = 'open' ORDER BY created_at, id",
            arguments: [projectID]
        )
    }

    /// A session's answered, delivered and withdrawn asks, newest first. A
    /// nil session lists the workbench's asks filed from outside the app.
    package static func closedAsks(_ db: Database, projectID: Int64, sessionID: Int64?) throws -> [OwnerAsk] {
        try OwnerAsk.fetchAll(
            db,
            sql: """
                SELECT * FROM owner_asks
                WHERE project_id = ? AND session_id IS ? AND status != 'open'
                ORDER BY created_at DESC, id DESC
                """,
            arguments: [projectID, sessionID]
        )
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

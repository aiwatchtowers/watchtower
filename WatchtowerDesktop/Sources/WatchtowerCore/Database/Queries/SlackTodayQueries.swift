import Foundation
import GRDB

/// The `slack-today` built-in as the Inbox reads it: its automation row and
/// the summary of its state (`automation_state.state_json`, `"today"`).
/// Read only; the daemon is the state's one writer.
package enum SlackTodayQueries {
    /// The built-in's id (`builtin.Entry`, Go).
    package static let builtinID = "slack-today"

    /// The built-in's row and its state's summary; nil summary = no state
    /// yet, or one this version cannot read.
    package struct Read: Equatable, Sendable {
        package let automationID: Int64
        package let summary: SlackTodaySummary?

        package init(automationID: Int64, summary: SlackTodaySummary?) {
            self.automationID = automationID
            self.summary = summary
        }
    }

    /// Nil when the built-in is not indexed, or on a database without the
    /// automation tables.
    package static func read(_ db: Database) throws -> Read? {
        do {
            guard let row = try Row.fetchOne(db, sql: """
                SELECT a.id, s.state_json FROM automations a
                LEFT JOIN automation_state s ON s.automation_id = a.id
                WHERE a.builtin_id = ?
                """, arguments: [builtinID]) else { return nil }
            let state: String? = row["state_json"]
            return Read(automationID: row["id"], summary: state.flatMap(SlackTodaySummary.decode(stateJSON:)))
        } catch let error as DatabaseError where ActionStripViewModel.isMissingTable(error) {
            return nil
        }
    }

    /// The summary alone; nil without the built-in's row or its state.
    package static func summary(_ db: Database) throws -> SlackTodaySummary? {
        try read(db)?.summary
    }
}

import Foundation
import GRDB

/// The `slack-today` built-in as the Inbox reads it: its automation row and
/// the summary of its state (`automation_state.state_json`, `"today"`).
/// Read only; the daemon is the state's one writer.
package enum SlackTodayQueries {
    /// The built-in's id (`builtin.Entry`, Go).
    package static let builtinID = "slack-today"

    /// The built-in's row and its state: none yet, read, or one this
    /// version cannot read.
    package struct Read: Equatable, Sendable {
        package let automationID: Int64
        package let state: SlackTodayState

        package init(automationID: Int64, state: SlackTodayState) {
            self.automationID = automationID
            self.state = state
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
            return Read(automationID: row["id"], state: state.map(SlackTodayState.decode(stateJSON:)) ?? .none)
        } catch let error as DatabaseError where ActionStripViewModel.isMissingTable(error) {
            return nil
        }
    }
}

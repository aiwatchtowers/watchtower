import Foundation
import GRDB

/// The owner's stored instruction for Watchman per session or target
/// (`watchman_instructions`, tuning spec §2, D7). Read only: `watchman arm
/// --instructions-file` and `watchman instruct` are its only writers. The
/// arm and edit sheets pre-fill it, so a text kept after Take back or an
/// app restart is never handed over or cleared unseen.
package enum WatchmanInstructionQueries {
    /// The stored text of `scope` ("" when none is stored; every running
    /// session has none of its own).
    package static func text(_ db: Database, scope: WatchmanArmScope) throws -> String {
        let key: (scope: String, id: Int64)
        switch scope {
        case let .session(id): key = ("session", id)
        case let .target(id): key = ("target", id)
        case .allRunning: return ""
        }
        return try String.fetchOne(db, sql: "SELECT text FROM watchman_instructions WHERE scope = ? AND ref_id = ?",
                                   arguments: [key.scope, key.id]) ?? ""
    }
}

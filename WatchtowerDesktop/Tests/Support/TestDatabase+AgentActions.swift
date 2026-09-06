import Foundation
import GRDB

/// Agent-action fixtures kept out of `TestDatabase.swift`, which is at its
/// SwiftLint file-length ceiling (the `TestDatabase+DatabaseManager` precedent).
extension TestDatabase {
    /// Insert an `agent_actions` row through `pool`'s SYNCHRONOUS write. An
    /// async test that must not yield the main actor before the row exists
    /// (the stream-end refresh hooks) cannot use GRDB's async `write` overload,
    /// which an `async` context would otherwise pick.
    package static func insertAgentActionSync(
        _ pool: DatabasePool,
        conversationID: Int64,
        turnID: String,
        status: String = "pending"
    ) throws {
        _ = try pool.write { db in
            try insertAgentAction(db, conversationID: conversationID, turnID: turnID, status: status)
        }
    }
}

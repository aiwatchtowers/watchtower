import Foundation
import GRDB

/// `chat_queued_drafts` (migration 00156, #604 S15): an embedded chat's queued
/// owner message, kept so an app quit before its turn starts brings it back
/// as an unsent draft (CHAT-01). The Desktop is the only reader and writer.
package enum QueuedDraftQueries {
    /// Stores (or replaces) the surface's queued text.
    package static func save(_ db: Database, key: String, text: String, at: Date) throws {
        try db.execute(sql: """
            INSERT INTO chat_queued_drafts (surface_key, text, at) VALUES (?, ?, ?)
            ON CONFLICT(surface_key) DO UPDATE SET text = excluded.text, at = excluded.at
            """, arguments: [key, text, at.timeIntervalSince1970])
    }

    /// Removes the surface's queued text; a missing row is fine.
    package static func clear(_ db: Database, key: String) throws {
        try db.execute(sql: "DELETE FROM chat_queued_drafts WHERE surface_key = ?", arguments: [key])
    }

    /// The surface's queued text; nil without one.
    package static func text(_ db: Database, key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT text FROM chat_queued_drafts WHERE surface_key = ?", arguments: [key])
    }
}

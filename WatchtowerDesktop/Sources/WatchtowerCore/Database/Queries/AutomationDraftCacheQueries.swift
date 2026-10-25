import Foundation
import GRDB

/// `automation_draft_cache` (migration 00156, #604 G2): the newest
/// `draft_automation` results of an automation editor chat, one
/// `DraftCacheEntry` JSON per row, oldest first by `seq`. Go writes it
/// (`internal/automations/authoring/draftcache.go`, newest five kept); the
/// Desktop reads it and deletes a saved or discarded draft's rows. Deleting
/// the conversation drops them by cascade.
package enum AutomationDraftCacheQueries {
    /// The conversation's entries, oldest first.
    package static func entries(_ db: Database, conversationID: Int64) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT entry_json FROM automation_draft_cache WHERE conversation_id = ? ORDER BY seq
            """, arguments: [conversationID])
    }

    /// The conversation's newest entry and when it was cached; nil without one.
    package static func newest(_ db: Database, conversationID: Int64) throws -> (entry: String, at: Date)? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT entry_json, at FROM automation_draft_cache WHERE conversation_id = ? ORDER BY seq DESC LIMIT 1
            """, arguments: [conversationID]) else { return nil }
        let at: String = row["at"]
        return (row["entry_json"], ISO8601DateFormatter().date(from: at) ?? .distantPast)
    }

    /// Removes a saved or discarded draft's cache.
    package static func delete(_ db: Database, conversationID: Int64) throws {
        try db.execute(sql: "DELETE FROM automation_draft_cache WHERE conversation_id = ?", arguments: [conversationID])
    }

    /// Appends one entry the way Go's `AppendDraftCache` does (seq = max + 1).
    /// Go is the writer in the app; tests and design shots seed rows with it.
    package static func append(_ db: Database, conversationID: Int64, entryJSON: String, at: Date) throws {
        try db.execute(sql: """
            INSERT INTO automation_draft_cache (conversation_id, seq, entry_json, at)
            SELECT ?, COALESCE(MAX(seq), 0) + 1, ?, ? FROM automation_draft_cache WHERE conversation_id = ?
            """, arguments: [conversationID, entryJSON, ISO8601DateFormatter().string(from: at), conversationID])
    }
}

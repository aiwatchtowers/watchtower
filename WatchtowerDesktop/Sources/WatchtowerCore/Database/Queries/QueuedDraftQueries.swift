import Foundation
import GRDB

/// `chat_queued_drafts` (migration 00157, #604 S15): an embedded chat's queued
/// owner message, kept so an app quit before its turn starts brings it back
/// as an unsent draft (CHAT-01). The Desktop is the only reader and writer.
package enum QueuedDraftQueries {

    /// The surface's queued text; nil without one.
    package static func text(_ db: Database, key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT text FROM chat_queued_drafts WHERE surface_key = ?", arguments: [key])
    }
}

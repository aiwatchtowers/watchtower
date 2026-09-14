import Foundation
import GRDB

/// The `inbox_items` table has no screen of its own since the inbox demolition —
/// the detector writes it and Catch-Up reads it. The one lookup left is resolving
/// a recap's `[inbox#id]` ref back to its item (`CatchUpViewModel`).
package enum InboxQueries {

    package static func fetchByID(_ db: Database, id: Int) throws -> InboxItem? {
        try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items WHERE id = ?", arguments: [id])
    }
}

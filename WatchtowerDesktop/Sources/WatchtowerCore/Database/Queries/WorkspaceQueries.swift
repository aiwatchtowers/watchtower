import GRDB
import Foundation

package enum WorkspaceQueries {
    package static func fetchWorkspace(_ db: Database) throws -> Workspace? {
        try Workspace.fetchOne(db, sql: "SELECT * FROM workspace LIMIT 1")
    }

    package static func fetchStats(_ db: Database) throws -> WorkspaceStats {
        try WorkspaceStats.fetch(db)
    }
}

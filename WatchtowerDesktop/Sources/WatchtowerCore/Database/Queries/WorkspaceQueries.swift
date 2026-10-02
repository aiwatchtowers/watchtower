import GRDB
import Foundation

package enum WorkspaceQueries {
    package static func fetchWorkspace(_ db: Database) throws -> Workspace? {
        try Workspace.fetchOne(db, sql: "SELECT * FROM workspace LIMIT 1")
    }
}

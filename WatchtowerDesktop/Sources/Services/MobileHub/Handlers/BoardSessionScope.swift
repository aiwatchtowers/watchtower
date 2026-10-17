import Foundation
import GRDB
import WatchtowerCore

extension TerminalSessionQueries {
    /// `id`'s row when it is an agent session of a workbench that still
    /// exists: the phone sees no other session. nil otherwise.
    static func fetchBoardSession(_ db: Database, id: Int64) throws -> TerminalSession? {
        guard let row = try fetch(db, id: id), row.kind.isAgent, let projectID = row.projectID,
              try WorkbenchQueries.fetch(db, id: projectID) != nil else { return nil }
        return row
    }
}

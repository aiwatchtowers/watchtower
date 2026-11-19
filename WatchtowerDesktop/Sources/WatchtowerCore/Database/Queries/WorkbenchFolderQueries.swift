import GRDB

/// Reads of `workbench_folders` (00209). Read-only: the Go CLI is the only
/// writer of folder membership (`workbench folder add|remove|locate`), the
/// Desktop calls it through `WorkbenchCLI`.
package enum WorkbenchFolderQueries {
    /// The workbench's folders in position order; removed ones only with
    /// `withRemoved`.
    package static func folders(_ db: Database, workbenchID: Int64, withRemoved: Bool) throws -> [WorkbenchFolder] {
        try WorkbenchFolder.fetchAll(db, sql: """
            SELECT id, workbench_id, folder_path, position, added_by, removed_at, name
            FROM workbench_folders
            WHERE workbench_id = ? \(withRemoved ? "" : "AND removed_at IS NULL")
            ORDER BY position, id
            """, arguments: [workbenchID])
    }

    /// The home folder's row id as Go's `db.HomeFolder` reads it: the live
    /// folder whose path is `projects.folder_path`, else the lowest-position
    /// row (a legacy bench whose only row 00209 marked removed). A scalar
    /// subquery bound to one workbench id; NULL for a workbench without
    /// folder rows.
    package static let homeFolderIDSQL = """
        (SELECT f.id FROM workbench_folders f JOIN projects p ON p.id = f.workbench_id
         WHERE f.workbench_id = ?
         ORDER BY (f.removed_at IS NULL AND f.folder_path = p.folder_path COLLATE NOCASE) DESC, f.position, f.id
         LIMIT 1)
        """

    /// `homeFolderIDSQL` on its own: nil for a workbench without folder rows.
    package static func homeFolderID(_ db: Database, workbenchID: Int64) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT \(homeFolderIDSQL)", arguments: [workbenchID])
    }

    /// Every folder row of the workbench (removed included) and its home, in
    /// one snapshot.
    package static func benchFolders(_ db: Database, workbenchID: Int64) throws -> BenchFolders {
        BenchFolders(folders: try folders(db, workbenchID: workbenchID, withRemoved: true),
                     homeID: try homeFolderID(db, workbenchID: workbenchID))
    }

    /// `benchFolders` of every workbench that has folder rows, in one read.
    package static func allBenchFolders(_ db: Database) throws -> [Int64: BenchFolders] {
        let rows = try WorkbenchFolder.fetchAll(db, sql: """
            SELECT id, workbench_id, folder_path, position, added_by, removed_at, name
            FROM workbench_folders
            ORDER BY workbench_id, position, id
            """)
        var benches: [Int64: BenchFolders] = [:]
        for (id, folders) in Dictionary(grouping: rows, by: \.workbenchID) {
            benches[id] = BenchFolders(folders: folders, homeID: try homeFolderID(db, workbenchID: id))
        }
        return benches
    }
}

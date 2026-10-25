import Foundation
import GRDB

/// `slice_assets` (#604 S12): each staged slice asset's `AssetDescriptor`
/// (its `K_asset`, header and plaintext digest), keyed by the staged file's
/// path relative to the `SliceAssets/` folder — in the sidecar database, not
/// in a `.desc` file beside the sealed one.
extension HubSyncState: SliceAssetDescriptorStoring {
    static func createSliceAssetTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS slice_assets (
                file_path TEXT PRIMARY KEY,
                descriptor BLOB NOT NULL
            )
            """)
    }

    func descriptor(forFile path: String) throws -> Data? {
        try queue.read { db in
            try Data.fetchOne(db, sql: "SELECT descriptor FROM slice_assets WHERE file_path = ?", arguments: [path])
        }
    }

    func setDescriptor(_ data: Data, forFile path: String) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO slice_assets (file_path, descriptor) VALUES (?, ?)
                ON CONFLICT(file_path) DO UPDATE SET descriptor = excluded.descriptor
                """, arguments: [path, data])
        }
    }

    func removeDescriptor(forFile path: String) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM slice_assets WHERE file_path = ?", arguments: [path])
        }
    }

    /// `directory` "" removes every row; otherwise the rows of the files
    /// below it (a plain prefix compare: record names hold `_`, a LIKE
    /// wildcard).
    func removeDescriptors(under directory: String) throws {
        try queue.write { db in
            if directory.isEmpty {
                try db.execute(sql: "DELETE FROM slice_assets")
            } else {
                let prefix = directory + "/"
                try db.execute(sql: "DELETE FROM slice_assets WHERE substr(file_path, 1, ?) = ?",
                               arguments: [prefix.unicodeScalars.count, prefix])
            }
        }
    }
}

import Foundation
import GRDB

/// A data-zone record's CKAsset as the replica holds it (the
/// `meeting_transcript` `segments.json`, mobile POC spec §4.11).
public enum SliceAsset: Equatable, Sendable {
    case data(Data)
    /// The record carried an asset but its file could not be read when the
    /// batch was applied: shown as a failure, never as a missing body.
    case unreadable(String)
}

extension ReplicaStore {
    /// The hub clips `segments.json` at 20 MB (spec §4.11); a larger file is
    /// refused unread, so a batch never pulls an oversized file into memory.
    public static let maxAssetBytes = 20 * 1_024 * 1_024

    static let sliceAssetsTableSQL = """
        CREATE TABLE IF NOT EXISTS slice_assets (
            record_name TEXT PRIMARY KEY,
            data BLOB,
            error TEXT
        )
        """

    /// The asset files of a batch's data records, read BEFORE the write
    /// transaction so file I/O never holds the write lock. A record without
    /// an asset maps to nil: applying it drops a stored asset.
    static func readAssets(of records: [CloudRecord]) -> [String: SliceAsset?] {
        var assets: [String: SliceAsset?] = [:]
        for record in records where record.zone == .data {
            guard let url = record.assetFileURL else {
                assets[record.recordName] = .some(nil)
                continue
            }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= maxAssetBytes else {
                    assets[record.recordName] = .unreadable("too large")
                    continue
                }
                assets[record.recordName] = .data(try Data(contentsOf: url))
            } catch {
                assets[record.recordName] = .unreadable(error.localizedDescription)
            }
        }
        return assets
    }

    func storeAsset(_ asset: SliceAsset?, recordName: String, in db: Database) throws {
        switch asset {
        case nil:
            try db.execute(sql: "DELETE FROM slice_assets WHERE record_name = ?", arguments: [recordName])
        case let .data(data):
            try upsertAsset(db, recordName: recordName, data: data, error: nil)
        case let .unreadable(reason):
            logger.error("asset of \(recordName, privacy: .public) unreadable: \(reason, privacy: .public)")
            try upsertAsset(db, recordName: recordName, data: nil, error: reason)
        }
    }

    private func upsertAsset(_ db: Database, recordName: String, data: Data?, error: String?) throws {
        try db.execute(
            sql: """
                INSERT INTO slice_assets (record_name, data, error) VALUES (?, ?, ?)
                ON CONFLICT(record_name) DO UPDATE SET data = excluded.data, error = excluded.error
                """,
            arguments: [recordName, data, error]
        )
    }

    /// The stored asset of one data-zone record, from an ALREADY-OPEN
    /// database; nil when the record carries none.
    public func sliceAsset(forRecordName recordName: String, from db: Database) throws -> SliceAsset? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT data, error FROM slice_assets WHERE record_name = ?",
            arguments: [recordName]
        ) else { return nil }
        if let data = row["data"] as Data? {
            return .data(data)
        }
        return .unreadable(row["error"] as String? ?? "The file did not arrive.")
    }
}

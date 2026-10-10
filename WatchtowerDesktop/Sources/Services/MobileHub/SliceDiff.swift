import CryptoKit
import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

/// Pure slice diffing: compares the current records of one kind against the
/// hashes last pushed to produce upserts, deletions and skipped records.
enum SliceDiff {
    private static let logger = Logger(subsystem: Constants.bundleID, category: "SliceDiff")

    struct Result: Equatable {
        let upserts: [SliceRecord]
        let deletions: [String]
        let skipped: [String]
    }

    /// Diffs SQL rows (`SlicePublisher.sliceSQL`): each row becomes a
    /// RowPayloadCoder record. A row whose id fell through
    /// `SlicePublisher.rowID`'s default branch (NULL or BLOB primary key)
    /// carries the sentinel "0" and is skipped, so invalid rows never share
    /// one record name.
    static func compute(
        kind: SliceKind,
        rows: [(id: String, row: Row)],
        knownHashes: [String: String],
        now: Date
    ) -> Result {
        var records: [SliceRecord] = []
        var skipped: [String] = []
        for (id, row) in rows {
            if id == "0" {
                let invalidName = "\(kind.rawValue)-invalid-id"
                logger.warning("slice row with null/blob id skipped: \(invalidName, privacy: .public)")
                skipped.append(invalidName)
                continue
            }
            do {
                records.append(SliceRecord(kind: kind, id: id, modifiedAt: now, payload: try RowPayloadCoder.payload(from: row)))
            } catch {
                skipped.append(kind.recordName(id: id))
            }
        }
        let diff = compute(kind: kind, records: records, knownHashes: knownHashes)
        return Result(upserts: diff.upserts, deletions: diff.deletions, skipped: skipped + diff.skipped)
    }

    /// Diffs ready-made records (a `SliceSource`). A record of another kind
    /// is skipped: deletions are computed per kind, so it could never be
    /// removed again. `assets` (record name → asset) feeds each asset-backed
    /// record's hash (`recordHash`).
    /// - Returns: upserts in `records` order; deletions sorted; skipped names.
    static func compute(
        kind: SliceKind,
        records: [SliceRecord],
        knownHashes: [String: String],
        assets: [String: SliceAsset] = [:]
    ) -> Result {
        var upserts: [SliceRecord] = []
        var skipped: [String] = []
        var seen = Set<String>()
        for record in records {
            guard record.kind == kind else {
                skipped.append(record.recordName)
                continue
            }
            seen.insert(record.recordName)
            if knownHashes[record.recordName] != recordHash(record, asset: assets[record.recordName]) {
                upserts.append(record)
            }
        }
        let deletions = knownHashes.keys.filter { !seen.contains($0) }.sorted()
        return Result(upserts: upserts, deletions: deletions, skipped: skipped)
    }

    /// The hash recorded for a published record: its payload's, or for an
    /// asset-backed record the payload plus the asset's content, so a change
    /// in the asset alone (a renamed speaker in the segments) republishes.
    static func recordHash(_ record: SliceRecord, asset: SliceAsset?) -> String {
        guard let asset else { return hashHex(record.payload) }
        return hashHex(record.payload + asset.digest)
    }

    /// SHA-256 hex digest of `data`. Exposed `internal` so tests can reproduce hashes.
    static func hashHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

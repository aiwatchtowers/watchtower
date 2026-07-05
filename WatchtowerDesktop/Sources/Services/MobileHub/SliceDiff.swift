import CryptoKit
import Foundation
import GRDB

/// Pure slice diffing: compares local DB rows against known pushed hashes
/// to produce a set of upserts, deletions, and skipped (un-encodable) records.
enum SliceDiff {
    struct Result: Equatable {
        let upserts: [SliceRecord]
        let deletions: [String]
        let skipped: [String]
    }

    /// Computes which rows need to be pushed to CloudKit.
    ///
    /// - Parameters:
    ///   - kind: The slice kind being diffed.
    ///   - rows: Current DB rows as `(id, row)` tuples, in the order they were read.
    ///   - knownHashes: recordName → payloadHash from the last push (from `HubSyncState`).
    ///   - now: Timestamp for `modifiedAt` on newly produced `SliceRecord`s.
    /// - Returns: Upserts in `rows` order; deletions sorted; skipped record names.
    static func compute(
        kind: SliceKind,
        rows: [(id: String, row: Row)],
        knownHashes: [String: String],
        now: Date
    ) -> Result {
        var upserts: [SliceRecord] = []
        var skipped: [String] = []
        var seenRecordNames = Set<String>()

        for (id, row) in rows {
            let recordName = kind.recordName(id: id)
            seenRecordNames.insert(recordName)

            let payload: Data
            do {
                payload = try RowPayloadCoder.payload(from: row)
            } catch {
                skipped.append(recordName)
                continue
            }

            let hash = hashHex(payload)
            if knownHashes[recordName] != hash {
                upserts.append(SliceRecord(kind: kind, id: id, modifiedAt: now, payload: payload))
            }
        }

        let deletions = knownHashes.keys
            .filter { !seenRecordNames.contains($0) }
            .sorted()

        return Result(upserts: upserts, deletions: deletions, skipped: skipped)
    }

    /// SHA-256 hex digest of `data`. Exposed `internal` so tests can reproduce hashes.
    static func hashHex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

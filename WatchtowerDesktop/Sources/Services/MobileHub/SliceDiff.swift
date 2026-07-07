import CryptoKit
import Foundation
import GRDB
import os

/// Pure slice diffing: compares local DB rows against known pushed hashes
/// to produce a set of upserts, deletions, and skipped (un-encodable) records.
enum SliceDiff {
    private static let logger = Logger(subsystem: Constants.bundleID, category: "SliceDiff")
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
            // Guard: a row whose id fell through SlicePublisher.rowID's default
            // branch (NULL or BLOB primary key) carries the sentinel "0".
            // Such a row must never enter the upsert path — doing so would assign
            // every invalid row the same record name (e.g. "target-0"), causing
            // silently incorrect CloudKit updates. Skip it with a distinct marker.
            // Known conflation: a LEGITIMATE id of 0 (explicit INTEGER 0 or TEXT
            // "0") is also skipped — unreachable for our autoincrement/calendar
            // ids today; if it ever matters, make rowID return String? instead.
            if id == "0" {
                let invalidName = "\(kind.rawValue)-invalid-id"
                logger.warning("slice row with null/blob id skipped: \(invalidName, privacy: .public)")
                skipped.append(invalidName)
                continue
            }
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
            let known = knownHashes[recordName]
            if known != hash {
                upserts.append(SliceRecord(
                    kind: kind,
                    id: id,
                    modifiedAt: now,
                    payload: payload,
                    notifyLevel: notifyLevel(kind: kind, row: row, isFirstPublish: known == nil, now: now)
                ))
            }
        }

        let deletions = knownHashes.keys
            .filter { !seenRecordNames.contains($0) }
            .sorted()

        return Result(upserts: upserts, deletions: deletions, skipped: skipped)
    }

    /// Plan 6 Decision 3 — the desktop decides what deserves a phone alert;
    /// the phone never re-derives importance from row contents:
    /// - "urgent": an inbox item that is priority high AND status pending.
    ///   State-derived, so every (re)publish while the item stays high+pending
    ///   carries it — the phone dedups alerts by recordName+modifiedAt
    ///   watermark (Plan 6 Task 4).
    /// - "briefing": today's briefing row when the record is NEW to the
    ///   sidecar hash state (`isFirstPublish` — no previous hash for its
    ///   recordName), i.e. its first-ever publish into the current sync
    ///   generation. A content republish of the same briefing (hash changed,
    ///   record known) stays nil, as do backfilled older briefings. After an
    ///   account reset wipes the sidecar, today's briefing IS new to the
    ///   fresh zone and re-carries the tag — intended: that zone's replica
    ///   has never alerted for it.
    /// Everything else is nil, which the Kit omits from the wire entirely
    /// (the `isError` discipline). Calendar-conflict level is out of v1
    /// (needs the day-plan conflict engine; ledgered).
    private static func notifyLevel(kind: SliceKind, row: Row, isFirstPublish: Bool, now: Date) -> String? {
        switch kind {
        case .inboxItem:
            let priority: String = row["priority"] ?? ""
            let status: String = row["status"] ?? ""
            return priority == "high" && status == "pending" ? "urgent" : nil
        case .briefing:
            let date: String = row["date"] ?? ""
            return isFirstPublish && date == localDateString(now) ? "briefing" : nil
        default:
            return nil
        }
    }

    /// The local-date string for `date`, matching how the Go pipeline stamps
    /// briefings.date (`time.Now().Format("2006-01-02")` — local time zone).
    private static func localDateString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    /// SHA-256 hex digest of `data`. Exposed `internal` so tests can reproduce hashes.
    static func hashHex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

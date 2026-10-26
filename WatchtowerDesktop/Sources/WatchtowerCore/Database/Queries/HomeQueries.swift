import Foundation
import GRDB

/// The read behind Home's Workbench zone: the open asks across workbenches
/// and the instruction suggestion, each read on its own so one failure keeps
/// the other (Review Focus 3). The live sessions come from the app; the feed,
/// links and numbers have their own reads.
package enum HomeQueries {
    /// Tables the Workbench read uses, for HomeCenter's ValueObservation region.
    package static let observedTables: [String] = ["owner_asks", "spec_reviews", "projects", "instruction_suggestions"]

    /// Both sources in one read. A read that throws is logged (NSLog, source
    /// + message) and marks the data failed; an unreadable ask does too, the
    /// readable rows still show. A table missing mid-migration reads as no
    /// content, not as a failure.
    package static func workbench(_ db: Database, now: Date) -> HomeWorkbenchData {
        var data = HomeWorkbenchData()
        data.asks = read("asks", db, tables: ["owner_asks", "projects"], failed: &data.failed) {
            try OwnerAskQueries.openAsksAllWorkbenches(db)
        } ?? WorkbenchAskRows(rows: [], unreadableIDs: [])
        if !data.asks.unreadableIDs.isEmpty { data.failed = true }
        if let value = read("instruction suggestion", db, tables: ["instruction_suggestions"], failed: &data.failed, {
            try newestOpenSuggestion(db, now: now)
        }) {
            data.suggestion = value
        }
        return data
    }

    /// The newest open suggestion first seen within 7 days.
    private static func newestOpenSuggestion(_ db: Database, now: Date) throws -> HomeInstructionSuggestion? {
        let cutoff = ISO8601DateFormatter().string(from: now.addingTimeInterval(-7 * 24 * 3600))
        let row = try Row.fetchOne(db, sql: """
            SELECT id, text, field FROM instruction_suggestions
            WHERE status = 'open' AND first_seen_at >= ?
            ORDER BY first_seen_at DESC, id DESC LIMIT 1
            """, arguments: [cutoff])
        return row.map { HomeInstructionSuggestion(id: $0["id"], text: $0["text"], field: $0["field"]) }
    }

    /// One source's read: nil when a table it needs is missing (no content)
    /// or when it throws (logged, `failed` set).
    private static func read<T>(
        _ source: String,
        _ db: Database,
        tables: [String],
        failed: inout Bool,
        _ body: () throws -> T
    ) -> T? {
        do {
            for table in tables where try !db.tableExists(table) {
                return nil
            }
            return try body()
        } catch {
            NSLog("HomeQueries: the Workbench %@ read failed: %@", source, "\(error)")
            failed = true
            return nil
        }
    }
}

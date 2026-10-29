import Foundation
import GRDB

/// The read behind Home's Workbench zone: the open asks across workbenches
/// and the coach proposal, each read on its own so one failure keeps
/// the other (Review Focus 3). The live sessions come from the app; the feed,
/// links and numbers have their own reads.
package enum HomeQueries {
    /// Tables the Workbench read uses, for HomeCenter's ValueObservation region.
    package static let observedTables: [String] = ["owner_asks", "spec_reviews", "projects", "coach_proposals"]

    /// Both sources in one read. A read that throws is logged (NSLog, source
    /// + message) and marks the data failed; an unreadable ask does too, the
    /// readable rows still show. A table missing mid-migration reads as no
    /// content, not as a failure.
    package static func workbench(_ db: Database, lastOpened: Int64? = nil) -> HomeWorkbenchData {
        var data = HomeWorkbenchData()
        data.asks = read("asks", db, tables: ["owner_asks", "projects"], failed: &data.failed) {
            try OwnerAskQueries.openAsksAllWorkbenches(db)
        } ?? WorkbenchAskRows(rows: [], unreadableIDs: [])
        if !data.asks.unreadableIDs.isEmpty { data.failed = true }
        if let value = read("coach proposal", db, tables: ["coach_proposals", "projects"], failed: &data.failed, {
            try newestCoachProposal(db, lastOpened: lastOpened)
        }) {
            data.coach = value
        }
        return data
    }

    /// Workbenches whose Agent analytics is on, lowest id first.
    package static func analyticsOnWorkbenches(_ db: Database) throws -> [Int64] {
        try Int64.fetchAll(db, sql: "SELECT id FROM projects WHERE agent_analytics = 1 ORDER BY id")
    }

    /// The newest open proposal that has a workbench with Analytics on to
    /// open it in (`CoachHomeRow.targetWorkbench`); the ones that have none
    /// are skipped, not hidden behind.
    package static func newestCoachProposal(_ db: Database, lastOpened: Int64?) throws -> HomeCoachProposal? {
        let on = try analyticsOnWorkbenches(db)
        guard !on.isEmpty else { return nil }
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM coach_proposals WHERE status = 'open' ORDER BY created_at DESC, id DESC
            """)
        for row in rows {
            let proposal = CoachProposal(row: row)
            if let target = CoachHomeRow.targetWorkbench(
                proposalWorkbench: proposal.workbenchID, analyticsOn: on, lastOpened: lastOpened) {
                return HomeCoachProposal(proposal: proposal, targetWorkbench: target)
            }
        }
        return nil
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

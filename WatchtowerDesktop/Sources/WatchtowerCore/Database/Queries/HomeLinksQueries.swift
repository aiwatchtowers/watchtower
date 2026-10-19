import Foundation
import GRDB

/// What the links zone needs from the database.
package struct HomeLinksData: Equatable, Sendable {
    /// The briefing dated today (local day).
    package var briefingToday: Briefing?
    /// The newest briefing of any day.
    package var latestBriefing: Briefing?
    /// The newest ready recap the owner has not acknowledged.
    package var pendingRecap: CatchUpRecap?
    /// Items done / total in today's day plan; both nil without a plan.
    package var dayPlanDone: Int?
    package var dayPlanTotal: Int?
    /// A read threw; the zone must not read as "nothing here".
    package var failed = false

    package init() {}
}

/// The read behind Home's links zone: one pass, each source caught on its own.
package enum HomeLinksQueries {
    /// Tables the read uses, for HomeCenter's ValueObservation region.
    package static let observedTables = ["briefings", "catchup_recaps", "day_plans", "day_plan_items"]

    /// A missing table (mid-migration) reads as no content; a throw is logged
    /// and sets `failed`, the other sources still read.
    package static func read(_ db: Database, now: Date, calendar: Calendar) -> HomeLinksData {
        var data = HomeLinksData()
        let day = localDay(now, calendar: calendar)
        if let value = guarded(db, tables: ["briefings"], failed: &data.failed, {
            (try BriefingQueries.fetchByDate(db, date: day), try BriefingQueries.fetchLatest(db))
        }) {
            (data.briefingToday, data.latestBriefing) = value
        }
        if let value = guarded(db, tables: ["catchup_recaps"], failed: &data.failed, {
            try CatchUpQueries.newestUnacknowledgedReady(db)
        }) {
            data.pendingRecap = value
        }
        if let value = guarded(db, tables: ["day_plans", "day_plan_items"], failed: &data.failed, {
            try DayPlanQueries.fetchByDate(db, date: day).map { plan -> (Int, Int) in
                let items = try DayPlanQueries.fetchItems(db, planId: plan.id)
                return (items.filter { $0.status == .done }.count, items.count)
            }
        }), let counts = value {
            (data.dayPlanDone, data.dayPlanTotal) = (counts.0, counts.1)
        }
        return data
    }

    private static func localDay(_ date: Date, calendar: Calendar) -> String {
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    private static func guarded<T>(
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
            NSLog("HomeLinksQueries: the links read failed: %@", "\(error)")
            failed = true
            return nil
        }
    }
}

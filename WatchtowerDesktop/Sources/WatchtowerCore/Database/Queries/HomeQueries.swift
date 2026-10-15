import Foundation
import GRDB

/// The Today read behind Home: every card's source in one pass, each card
/// read on its own so one failure hides only that card (Review Focus 3).
package enum HomeQueries {
    /// Tables the Today read uses, for HomeCenter's ValueObservation region.
    package static let observedTables: [String] = [
        "agent_actions", "reminders",
        "calendar_events", "calendar_calendars", "google_accounts", "meeting_prep_cache",
        "briefings", "targets", "owner_asks", "projects", "catchup_recaps"
    ]

    /// Every Today source in one read. Each card's read is caught separately:
    /// its error is logged (NSLog, card kind + message) and its kind added to
    /// `failed`; the others still read. A table missing mid-migration reads as
    /// that card having no content, not as a failure.
    package static func today(_ db: Database, now: Date, calendar: Calendar) -> HomeTodayData {
        var data = HomeTodayData()
        let nowUTC = ISO8601DateFormatter().string(from: now)
        let day = HomeTodayBuilder.dayString(now, calendar: calendar)

        if let value = readCard(.waitingOnYou, db, tables: ["agent_actions", "reminders"], failed: &data.failed, {
            (try AgentActionQueries.awaitingOwnerCount(db),
             try AgentActionQueries.awaitingOwner(db, limit: 3),
             try ReminderQueries.fetchDue(db, nowUTC: nowUTC))
        }) {
            (data.awaitingCount, data.actions, data.reminders) = value
        }
        let calendarTables = ["calendar_events", "calendar_calendars", "google_accounts", "meeting_prep_cache"]
        if let value = readCard(.nextMeeting, db, tables: calendarTables, failed: &data.failed, {
            let event = try CalendarQueries.fetchNextEvent(db)
            return (event, try event.map { try CalendarQueries.hasPrep(db, eventID: $0.id) } ?? false)
        }) {
            (data.nextEvent, data.nextEventHasPrep) = value
        }
        if let value = readCard(.briefing, db, tables: ["briefings"], failed: &data.failed, {
            try BriefingQueries.fetchByDate(db, date: day)
        }) {
            data.briefing = value
        }
        data.targets = readCard(.myTargets, db, tables: ["targets"], failed: &data.failed) {
            try TargetQueries.homeSummary(db, today: day)
        } ?? []
        data.asks = readCard(.agentsWaiting, db, tables: ["owner_asks", "projects"], failed: &data.failed) {
            try OwnerAskQueries.openAsksAllWorkbenches(db)
        } ?? WorkbenchAskRows(rows: [], unreadableIDs: [])
        if let value = readCard(.sinceYouWereAway, db, tables: ["catchup_recaps"], failed: &data.failed, {
            try CatchUpQueries.fetchRecaps(db, limit: 1).first
        }) {
            data.latestRecap = value
        }
        return data
    }

    /// One card's read: nil when a table it needs is missing (no content) or
    /// when it throws (logged, `kind` added to `failed`).
    private static func readCard<T>(
        _ kind: TodayCardKind,
        _ db: Database,
        tables: [String],
        failed: inout Set<TodayCardKind>,
        _ body: () throws -> T
    ) -> T? {
        do {
            for table in tables where try !db.tableExists(table) {
                return nil
            }
            return try body()
        } catch {
            NSLog("HomeQueries: the Today %@ read failed: %@", "\(kind)", "\(error)")
            failed.insert(kind)
            return nil
        }
    }
}

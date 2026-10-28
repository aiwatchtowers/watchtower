import Foundation
import GRDB

/// The small counts behind Home's "Today in numbers" zone. A nil value is a
/// source that is absent or off (left out of the zone); a read that threw
/// leaves its value nil and adds its field name to `failed` (rendered "—").
package struct HomeNumbers: Equatable, Sendable {
    package var messagesToMe: Int?
    package var messagesSent: Int?
    package var meetings: Int?
    package var meetingHours: Double?
    package var plan5h: Int?
    package var planWeek: Int?
    package var workbenchCreated: Int?
    package var workbenchDone: Int?
    package var meetingsRecorded: Int?
    package var failed: Set<String> = []

    package init() {}
}

/// Today's numbers, one independent read per group: a failing source marks
/// its own fields failed and never blanks the rest. Reads only; no AI.
package enum HomeNumbersQueries {
    package static let observedTables = [
        "messages", "calendar_events", "plan_usage_status",
        "target_status_history", "meeting_transcripts", "slack_accounts"
    ]

    package static func read(_ db: Database, now: Date, calendar: Calendar) -> HomeNumbers {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        var numbers = HomeNumbers()
        var failed = Set<String>()

        group(&failed, ["messagesToMe", "messagesSent"]) {
            let owners = try ownerIDs(db)
            guard !owners.isEmpty else { return }
            let (to, sent) = try messageCounts(db, owners: owners, start: start, end: end)
            numbers.messagesToMe = to
            numbers.messagesSent = sent
        }
        group(&failed, ["meetings", "meetingHours"]) {
            guard try db.tableExists("calendar_calendars"),
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM calendar_calendars") ?? 0 > 0 else { return }
            let events = try CalendarQueries.fetchEvents(db, from: start, to: end)
                .filter { HomeFeedQueries.isShownEvent($0) && $0.startDate >= start && $0.startDate < end }
            numbers.meetings = events.count
            let seconds = events.reduce(0.0) { $0 + max(0, $1.endDate.timeIntervalSince($1.startDate)) }
            numbers.meetingHours = (seconds / 3600 * 2).rounded() / 2
        }
        group(&failed, ["plan5h", "planWeek"]) {
            guard let status = try PlanUsageQueries.status(db), status.state == "ok" else { return }
            numbers.plan5h = status.limits.first { $0.key == "session" }.map { Int($0.percent.rounded()) }
            numbers.planWeek = status.limits.first { $0.key == "weekly_all" }.map { Int($0.percent.rounded()) }
        }
        group(&failed, ["workbenchCreated", "workbenchDone"]) {
            let (created, done) = try workbenchCounts(db, start: start, end: end)
            numbers.workbenchCreated = created
            numbers.workbenchDone = done
        }
        group(&failed, ["meetingsRecorded"]) {
            numbers.meetingsRecorded = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM meeting_transcripts WHERE created_at >= ? AND created_at < ?
                """, arguments: [iso(start), iso(end)])
        }
        numbers.failed = failed
        return numbers
    }

    /// Runs one group; a throw is logged and marks every field of the group failed.
    private static func group(_ failed: inout Set<String>, _ fields: [String], _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            NSLog("HomeNumbersQueries: the %@ read failed: %@", fields.joined(separator: "/"), "\(error)")
            failed.formUnion(fields)
        }
    }

    // MARK: - Messages

    /// The owner's namespaced Slack user id on every account still connected
    /// (`OwnerQueries.ownSlackUserIDs`, OWNER-01).
    private static func ownerIDs(_ db: Database) throws -> [String] {
        guard try db.tableExists("slack_accounts") else { return [] }
        return try OwnerQueries.ownSlackUserIDs(db)
    }

    /// To me: not mine, not deleted, in a DM or naming me; sent: mine. Both today only.
    /// `messages.user_id` is namespaced; `<@U…>` mentions in the text are raw.
    private static func messageCounts(
        _ db: Database, owners: [String], start: Date, end: Date
    ) throws -> (toMe: Int, sent: Int) {
        let marks = owners.map { _ in "?" }.joined(separator: ",")
        let window: [DatabaseValueConvertible] = [start.timeIntervalSince1970, end.timeIntervalSince1970]
        let raws = owners.map { $0.split(separator: ":", maxSplits: 1).last.map(String.init) ?? $0 }
        let mentions = raws.map { _ in "m.text LIKE '%<@' || ? || '>%'" }.joined(separator: " OR ")
        let toMe = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM messages m
            WHERE m.ts_unix >= ? AND m.ts_unix < ? AND m.is_deleted = 0 AND m.user_id NOT IN (\(marks))
              AND (m.channel_id IN (SELECT id FROM channels WHERE type IN ('dm','group_dm')) OR \(mentions))
            """, arguments: StatementArguments(window + owners + raws)) ?? 0
        let sent = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM messages
            WHERE ts_unix >= ? AND ts_unix < ? AND is_deleted = 0 AND user_id IN (\(marks))
            """, arguments: StatementArguments(window + owners)) ?? 0
        return (toMe, sent)
    }

    // MARK: - Workbench

    /// Targets of a workbench created (no previous status) and moved to done today.
    private static func workbenchCounts(_ db: Database, start: Date, end: Date) throws -> (created: Int, done: Int) {
        let row = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(h.from_status IS NULL), 0) AS created,
                   COALESCE(SUM(h.to_status = 'done'), 0) AS done
            FROM target_status_history h JOIN targets t ON t.id = h.target_id
            WHERE t.project_id IS NOT NULL AND h.changed_at >= ? AND h.changed_at < ?
            """, arguments: [iso(start), iso(end)])
        return (row?["created"] ?? 0, row?["done"] ?? 0)
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

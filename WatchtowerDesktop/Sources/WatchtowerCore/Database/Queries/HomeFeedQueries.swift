import Foundation
import GRDB

/// One inbox row of the feed with the names it shows.
package struct HomeFeedInboxRow: Equatable, Sendable {
    package let item: InboxItem
    /// `MAX(created_at, mentioned_at)`.
    package let stamp: Date
    /// The sender: a name, the from address, or the Jira issue key.
    package let who: String
    /// "#eng", the mail subject, or the Jira reason; nil when there is none.
    package let whereText: String?
    /// The display names of an accumulated item's senders, keyed by their
    /// namespaced id; a sender with no name is left out.
    package var senderNames: [String: String] = [:]
}

/// Every feed source as one read (`HomeFeedQueries.read`) left it.
package struct HomeFeedData: Equatable, Sendable {
    package var inbox: [HomeFeedInboxRow] = []
    /// Pending reminders already due.
    package var dueReminders: [Reminder] = []
    /// Pending reminders that fire later today.
    package var laterReminders: [Reminder] = []
    package var proposals: [AgentAction] = []
    /// Unread automation inbox outputs, newest first.
    package var outputs: [AutomationOutputCard] = []
    /// Overdue or due today, never a workbench target (PROJ-01).
    package var targets: [Target] = []
    /// Today and the next days, only the events `HomeFeedQueries.isShownEvent` accepts.
    package var events: [CalendarEvent] = []
    /// Events with a prep, for the ones still to start today and the next day's.
    package var prepEventIDs: Set<String> = []
    /// A source whose read threw (logged).
    package var failed: Set<FeedSource> = []

    package init() {}
}

/// The feed read behind Home: each source on its own, so one failure hides
/// only that source.
package enum HomeFeedQueries {
    /// Tables the feed read uses, for HomeCenter's ValueObservation region.
    package static let observedTables: [String] = [
        "inbox_items", "reminders", "agent_actions", "automation_outputs", "automations", "targets",
        "calendar_events", "calendar_calendars", "google_accounts", "meeting_prep_cache"
    ]

    private static let windowHours = 72.0
    /// Every source's row bound; the builder caps what shows.
    private static let rowLimit = 200
    private static let calendarDays = 4
    private static let nextDayHorizon = 3
    /// The triggers of a Messages row; the Inbox's Messages filter reads the same set.
    package static let feedTriggers = [
        "mention", "dm", "thread_reply", "reaction",
        "jira_assigned", "jira_comment_mention", "linear_assigned", "linear_comment_mention",
        "email_received"
    ]

    /// Every feed source in one read. A source's error is logged and the
    /// source added to `failed`; the others still read. A table missing
    /// mid-migration reads as that source having no content.
    package static func read(_ db: Database, now: Date, calendar: Calendar) -> HomeFeedData {
        var data = HomeFeedData()
        let nowUTC = ISO8601DateFormatter().string(from: now)
        let today = HomeFeedBuilder.dayString(now, calendar: calendar)
        let startOfDay = calendar.startOfDay(for: now)

        data.inbox = readSource(.inbox, db, tables: ["inbox_items", "users", "channels"], failed: &data.failed) {
            try inboxRows(db, now: now)
        } ?? []
        if let value = readSource(.reminders, db, tables: ["reminders"], failed: &data.failed, {
            let end = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? now
            return (try ReminderQueries.fetchDue(db, nowUTC: nowUTC),
                    try ReminderQueries.fetchPending(
                        db, fromUTC: nowUTC, toUTC: ISO8601DateFormatter().string(from: end)))
        }) {
            (data.dueReminders, data.laterReminders) = value
        }
        data.proposals = readSource(.proposals, db, tables: ["agent_actions"], failed: &data.failed) {
            try AgentActionQueries.awaitingOwner(db, limit: rowLimit)
        } ?? []
        let cutoff = now.addingTimeInterval(-windowHours * 3600)
        data.outputs = readSource(.automations, db, tables: ["automation_outputs", "automations"], failed: &data.failed) {
            try AutomationQueries.fetchInboxOutputs(db, since: cutoff, limit: rowLimit, includeRead: false)
        } ?? []
        data.targets = readSource(.targets, db, tables: ["targets"], failed: &data.failed) {
            try dueTargets(db, today: today)
        } ?? []
        let calendarTables = ["calendar_events", "calendar_calendars", "google_accounts", "meeting_prep_cache"]
        if let value = readSource(.calendar, db, tables: calendarTables, failed: &data.failed, {
            try events(db, now: now, calendar: calendar)
        }) {
            (data.events, data.prepEventIDs) = value
        }
        return data
    }

    // MARK: - Inbox

    private static func inboxRows(_ db: Database, now: Date) throws -> [HomeFeedInboxRow] {
        let formatter = ISO8601DateFormatter()
        let cutoff = formatter.string(from: now.addingTimeInterval(-windowHours * 3600))
        return try openMessageRows(db, now: now, since: cutoff, limit: rowLimit)
    }

    /// The open messages clause every Messages read shares (Home's feed, the
    /// Inbox's Messages filter and its badge): pending actionable rows of the
    /// feed triggers that are not archived or snoozed. One `?`: the current time.
    package static let openMessageClause = """
        status = 'pending' AND item_class = 'actionable' AND archived_at IS NULL
        AND trigger_type IN (\(feedTriggers.map { "'\($0)'" }.joined(separator: ", ")))
        AND (snooze_until = '' OR snooze_until <= ?)
        """

    /// The open messages, newest first by `MAX(created_at, mentioned_at)`,
    /// optionally only those at or after `since` (RFC 3339 UTC).
    package static func openMessageRows(
        _ db: Database, now: Date, since: String?, limit: Int
    ) throws -> [HomeFeedInboxRow] {
        var arguments: [any DatabaseValueConvertible] = [ISO8601DateFormatter().string(from: now)]
        var sinceClause = ""
        if let since {
            sinceClause = " AND MAX(created_at, mentioned_at) >= ?"
            arguments.append(since)
        }
        arguments.append(limit)
        let rows = try Row.fetchAll(db, sql: """
            SELECT *, MAX(created_at, mentioned_at) AS stamp FROM inbox_items
            WHERE \(openMessageClause)\(sinceClause)
            ORDER BY stamp DESC, id DESC
            LIMIT ?
            """, arguments: StatementArguments(arguments))
        return try rows.map { row in
            let item = InboxItem(row: row)
            let stamp: String = row["stamp"] ?? ""
            let names = try senderNames(db, item)
            return HomeFeedInboxRow(
                item: item,
                stamp: parse(stamp) ?? now,
                who: try who(db, item, senderNames: names),
                whereText: try whereText(db, item),
                senderNames: names
            )
        }
    }

    private static func isSlack(_ item: InboxItem) -> Bool {
        ["mention", "dm", "thread_reply", "reaction"].contains(item.triggerType)
    }

    /// The sender; an accumulated item's from its `senderNames`.
    package static func who(_ db: Database, _ item: InboxItem, senderNames: [String: String]) throws -> String {
        if item.triggerType.hasPrefix("jira_") || item.triggerType.hasPrefix("linear_") { return item.channelID }
        if item.triggerType == "email_received" { return item.senderUserID }
        if item.isAccumulated {
            return item.mentionSendersLabel(names: senderNames)
        }
        // fetchByID, not fetchDisplayName: a raw id would read as noise.
        return try UserQueries.fetchByID(db, id: item.senderUserID)?.bestName ?? ""
    }

    /// An accumulated item's sender names (`who`'s and the message card's).
    package static func senderNames(_ db: Database, _ item: InboxItem) throws -> [String: String] {
        guard item.isAccumulated else { return [:] }
        var names: [String: String] = [:]
        for id in Set(item.mentionList.map(\.sender)) {
            if let name = try UserQueries.fetchByID(db, id: id)?.bestName, !name.isEmpty {
                names[id] = name
            }
        }
        return names
    }

    package static func whereText(_ db: Database, _ item: InboxItem) throws -> String? {
        switch item.triggerType {
        case "jira_assigned", "linear_assigned": return "assigned to you"
        case "jira_comment_mention", "linear_comment_mention": return "mentioned you"
        case "email_received":
            let subject = item.snippet.components(separatedBy: " — ").first ?? ""
            return subject.isEmpty ? nil : subject
        default:
            // A DM names no channel.
            guard isSlack(item), item.triggerType != "dm",
                  let name = try ChannelQueries.fetchByID(db, id: item.channelID)?.name, !name.isEmpty
            else { return nil }
            return "#\(name)"
        }
    }

    package static func parse(_ stamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
    }

    // MARK: - Targets

    /// The owner's open targets that are overdue or due today (a timed one
    /// due later today too: the builder puts it below NOW).
    private static func dueTargets(_ db: Database, today: String) throws -> [Target] {
        // BEHAVIOR PROJ-01 — project targets live only on their board
        // (WorkbenchQueries.board); Home never sees one.
        try Target.fetchAll(db, sql: """
            SELECT * FROM targets
            WHERE project_id IS NULL AND ownership = 'mine'
            AND status IN ('todo', 'in_progress', 'in_review', 'blocked')
            AND (due_date != '' AND due_date < ?)
            ORDER BY due_date, id
            LIMIT ?
            """, arguments: [today + "T24:00", rowLimit])
    }

    // MARK: - Calendar

    private static func events(
        _ db: Database, now: Date, calendar: Calendar
    ) throws -> ([CalendarEvent], Set<String>) {
        let startOfDay = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: calendarDays, to: startOfDay) ?? now
        let events = try CalendarQueries.fetchEvents(db, from: startOfDay, to: end).filter(isShownEvent)
        // Prep is read for the events still to start today and the next day's only.
        let nextDay = (1...nextDayHorizon).lazy
            .compactMap { calendar.date(byAdding: .day, value: $0, to: startOfDay) }
            .first { day in events.contains { calendar.isDate($0.startDate, inSameDayAs: day) } }
        let wanted = events.filter { event in
            if calendar.isDate(event.startDate, inSameDayAs: now) { return event.startDate > now }
            return nextDay.map { calendar.isDate(event.startDate, inSameDayAs: $0) } ?? false
        }
        var prep = Set<String>()
        for event in wanted where try CalendarQueries.hasPrep(db, eventID: event.id) {
            prep.insert(event.id)
        }
        return (events, prep)
    }

    /// Whether Home shows an event: timed, not cancelled, not declined by the owner.
    package static func isShownEvent(_ event: CalendarEvent) -> Bool {
        !event.isAllDay && event.eventStatus != "cancelled" && !ownerDeclined(event)
    }

    /// The owner is the attendee whose email is the event's account email.
    private static func ownerDeclined(_ event: CalendarEvent) -> Bool {
        guard let owner = event.accountEmail, !owner.isEmpty else { return false }
        return event.parsedAttendees.contains {
            $0.email.caseInsensitiveCompare(owner) == .orderedSame && $0.responseStatus == "declined"
        }
    }

    // MARK: - Source read

    /// One source's read: nil when a table it needs is missing (no content)
    /// or when it throws (logged, `source` added to `failed`).
    private static func readSource<T>(
        _ source: FeedSource,
        _ db: Database,
        tables: [String],
        failed: inout Set<FeedSource>,
        _ body: () throws -> T
    ) -> T? {
        do {
            for table in tables where try !db.tableExists(table) {
                return nil
            }
            return try body()
        } catch {
            NSLog("HomeFeedQueries: the %@ read failed: %@", "\(source)", "\(error)")
            failed.insert(source)
            return nil
        }
    }
}

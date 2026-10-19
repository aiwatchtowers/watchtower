import Foundation

/// Turns the feed read into the feed Home shows: what waits above NOW (kind
/// order, newest first, capped), the NOW line, the rest of today and the
/// first later day with meetings. Pure: no read, no clock of its own.
package enum HomeFeedBuilder {
    /// Rows shown above NOW before "N more".
    package static let waitingLimit = 7
    /// How many days ahead the next day with meetings is looked for.
    package static let nextDayHorizonDays = 3

    private static let nextDayLimit = 3
    private static let soonMinutes = 60

    /// `hidden` holds the rows the owner just pressed Done / Hide on, so
    /// they leave before the next read lands.
    package static func feed(
        _ data: HomeFeedData,
        now: Date,
        calendar: Calendar,
        expanded: Bool,
        hidden: Set<FeedRef>
    ) -> HomeFeed {
        let rows = waitingRows(data, now: now, calendar: calendar).filter { !hidden.contains($0.id) }
        let shown = expanded ? rows : Array(rows.prefix(waitingLimit))
        let today = events(data, now: now, calendar: calendar, hidden: hidden)
        return HomeFeed(
            waiting: shown,
            hiddenWaiting: rows.count - shown.count,
            nowLabel: format("HH:mm", now, calendar),
            ongoing: today.ongoing,
            laterToday: today.later,
            nextDay: nextDay(data, now: now, calendar: calendar),
            failed: data.failed
        )
    }

    // MARK: - Above NOW

    private static func waitingRows(_ data: HomeFeedData, now: Date, calendar: Calendar) -> [FeedRow] {
        var rows = data.inbox.map(inboxRow)
        rows += data.dueReminders.map { reminder in
            FeedRow(
                id: .reminder(reminder.id), kind: .reminder, chip: "Reminder",
                who: reminder.note.isEmpty ? "Reminder" : reminder.note, whereText: nil, text: "Reminder",
                stamp: instant(reminder.remindAt), read: false, actions: [.done, .hide], link: .inbox)
        }
        rows += data.proposals.map { action in
            FeedRow(
                id: .proposal(action.id), kind: .proposal, chip: action.status == "failed" ? "Failed" : "Proposal",
                who: action.reason.isEmpty ? ReactionToolCatalog.title(for: action.tool) : action.reason,
                whereText: nil, text: "Drafted by the assistant \u{00B7} review in Inbox",
                stamp: instant(action.createdAt), read: false, actions: [], link: .inbox)
        }
        for target in data.targets {
            let due = dueInstant(target.dueDate, calendar: calendar)
            // Due later today with a time sits below NOW instead.
            if target.dueDate.contains("T"), due > now { continue }
            let overdue = target.dueDate.contains("T") ? due <= now : String(target.dueDate.prefix(10)) < dayString(now, calendar: calendar)
            rows.append(FeedRow(
                id: .target(target.id), kind: .target, chip: overdue ? "Overdue" : "Due", who: target.text, whereText: nil,
                text: "My target", stamp: due, read: false, actions: [.done, .hide], link: .target(id: target.id)))
        }
        // Kind order, newest first; the sort is stable via the offset.
        return rows.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.kind != rhs.element.kind { return lhs.element.kind < rhs.element.kind }
                if lhs.element.stamp != rhs.element.stamp { return lhs.element.stamp > rhs.element.stamp }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func inboxRow(_ row: HomeFeedInboxRow) -> FeedRow {
        let item = row.item
        let (kind, chip): (FeedKind, String) = switch item.triggerType {
        case "mention": (.slack, "Mention")
        case "dm": (.slack, "DM")
        case "thread_reply": (.slack, "Thread")
        case "reaction": (.slack, "Reaction")
        case "email_received": (.email, "Email")
        default: (.jira, "Jira")
        }
        var who = row.who
        var whereText = row.whereText
        // An unresolved Slack sender shows the place instead of a raw id.
        if who.isEmpty {
            who = whereText ?? ""
            whereText = nil
            if who.isEmpty { who = "Slack" }
        }
        return FeedRow(
            id: .inbox(item.id), kind: kind, chip: chip, who: who, whereText: whereText, text: item.snippet,
            stamp: row.stamp, read: !item.isUnread, actions: [.done, .hide],
            link: permalink(item.permalink).map { .permalink($0) } ?? .catchUp)
    }

    /// The item's permalink when it is an absolute URL; an empty or
    /// scheme-less one is nil, and the row opens Catch-Up instead.
    private static func permalink(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme, !scheme.isEmpty else { return nil }
        return url
    }

    // MARK: - Below NOW

    private static func events(
        _ data: HomeFeedData, now: Date, calendar: Calendar, hidden: Set<FeedRef>
    ) -> (ongoing: FeedEvent?, later: [FeedEvent]) {
        var ongoing: FeedEvent?
        var later: [FeedEvent] = []
        for event in data.events.sorted(by: { $0.startDate < $1.startDate }) {
            if event.startDate <= now, now < event.endDate {
                if ongoing == nil {
                    ongoing = feedEvent(event, data, chip: "until \(format("HH:mm", event.endDate, calendar))",
                                        isNext: false, isOngoing: true)
                }
            } else if event.startDate > now, calendar.isDate(event.startDate, inSameDayAs: now) {
                later.append(feedEvent(event, data, chip: "Meeting", isNext: false, isOngoing: false))
            }
        }
        // The first upcoming meeting says how soon it starts.
        if let first = later.indices.first {
            let minutes = Int(later[first].start.timeIntervalSince(now) / 60)
            let old = later[first]
            later[first] = FeedEvent(
                id: old.id, start: old.start, end: old.end, title: old.title,
                chip: minutes < 1 ? "now" : minutes < soonMinutes ? "in \(minutes) min" : old.chip,
                prepReady: old.prepReady, isNext: true, isOngoing: false, link: old.link)
        }
        for target in data.targets where target.dueDate.contains("T") {
            let due = dueInstant(target.dueDate, calendar: calendar)
            guard due > now, calendar.isDate(due, inSameDayAs: now) else { continue }
            later.append(FeedEvent(
                id: .target(target.id), start: due, end: due, title: target.text, chip: "Due",
                prepReady: false, isNext: false, isOngoing: false, link: .target(id: target.id)))
        }
        for reminder in data.laterReminders {
            let at = instant(reminder.remindAt)
            guard at > now else { continue }
            later.append(FeedEvent(
                id: .reminder(reminder.id), start: at, end: at, title: reminder.note.isEmpty ? "Reminder" : reminder.note,
                chip: "Reminder", prepReady: false, isNext: false, isOngoing: false, link: .inbox))
        }
        let sorted = later.enumerated().sorted { lhs, rhs in
            lhs.element.start != rhs.element.start ? lhs.element.start < rhs.element.start : lhs.offset < rhs.offset
        }
        return (ongoing, sorted.map(\.element).filter { !hidden.contains($0.id) })
    }

    /// The first day after today with meetings, within the horizon; meetings only.
    private static func nextDay(_ data: HomeFeedData, now: Date, calendar: Calendar) -> FeedDay? {
        let startOfDay = calendar.startOfDay(for: now)
        for offset in 1...nextDayHorizonDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfDay) else { continue }
            let events = data.events
                .filter { calendar.isDate($0.startDate, inSameDayAs: day) }
                .sorted { $0.startDate < $1.startDate }
            guard !events.isEmpty else { continue }
            return FeedDay(
                title: offset == 1 ? "Tomorrow" : format("EEEE", day, calendar),
                events: events.prefix(nextDayLimit).map {
                    feedEvent($0, data, chip: "Meeting", isNext: false, isOngoing: false)
                })
        }
        return nil
    }

    private static func feedEvent(
        _ event: CalendarEvent, _ data: HomeFeedData, chip: String, isNext: Bool, isOngoing: Bool
    ) -> FeedEvent {
        FeedEvent(
            id: .event(event.id), start: event.startDate, end: event.endDate, title: event.title, chip: chip,
            prepReady: data.prepEventIDs.contains(event.id), isNext: isNext, isOngoing: isOngoing,
            link: .calendarEvent(id: event.id))
    }

    // MARK: - Helpers

    /// `date` as "yyyy-MM-dd" in `calendar`'s zone — `TargetQueries.todayDateString()`'s
    /// form. Gregorian (the POSIX locale's), so it matches the stored columns
    /// whatever calendar the owner uses.
    package static func dayString(_ date: Date, calendar: Calendar) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    /// An RFC 3339 UTC stamp as a date; an unparseable one sorts last.
    private static func instant(_ stamp: String) -> Date {
        ISO8601DateFormatter().date(from: stamp) ?? .distantPast
    }

    /// A target's "yyyy-MM-dd[THH:mm]" due date as local wall-clock time; a
    /// bare day is its midnight.
    private static func dueInstant(_ due: String, calendar: Calendar) -> Date {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = due.contains("T") ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
        return fmt.date(from: String(due.prefix(due.contains("T") ? 16 : 10))) ?? .distantPast
    }

    /// Gregorian (the POSIX locale's) in `calendar`'s zone.
    private static func format(_ pattern: String, _ date: Date, _ calendar: Calendar) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = pattern
        return fmt.string(from: date)
    }
}

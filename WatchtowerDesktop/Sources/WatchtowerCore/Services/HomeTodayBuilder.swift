import Foundation

/// Turns the Today read into Home's cards: each shows only with content, in
/// `TodayCardKind`'s fixed order, and only when the caller allows its kind.
/// Pure: no read, no clock of its own.
package enum HomeTodayBuilder {
    package static let nextMeetingHorizon: TimeInterval = 24 * 60 * 60

    /// How many rows a list card shows.
    private static let itemLimit = 3

    package static func cards(
        _ data: HomeTodayData,
        allowed: Set<TodayCardKind>,
        now: Date,
        calendar: Calendar
    ) -> [TodayCard] {
        TodayCardKind.allCases.filter(allowed.contains).compactMap { kind in
            switch kind {
            case .waitingOnYou: waitingOnYou(data)
            case .nextMeeting: nextMeeting(data, now: now, calendar: calendar)
            case .briefing: briefing(data)
            case .myTargets: myTargets(data, today: dayString(now, calendar: calendar))
            case .agentsWaiting: agentsWaiting(data)
            case .sinceYouWereAway: sinceYouWereAway(data, calendar: calendar)
            }
        }
    }

    /// The first item of the first non-empty section, in the briefing's order.
    package static func briefingSummary(_ briefing: Briefing) -> String? {
        briefing.parsedAttention.first?.text
            ?? briefing.parsedYourDay.first?.text
            ?? briefing.parsedWhatHappened.first?.text
            ?? briefing.parsedTeamPulse.first?.text
            ?? briefing.parsedCoaching.first?.text
    }

    /// "IN N MIN" under an hour, "HH:MM" later today, "TOMORROW HH:MM" otherwise.
    package static func meetingEyebrow(start: Date, now: Date, calendar: Calendar) -> String {
        let delta = start.timeIntervalSince(now)
        if delta < 60 * 60 {
            return "NEXT MEETING · IN \(max(0, Int(delta / 60))) MIN"
        }
        let time = format("HH:mm", start, calendar)
        return calendar.isDate(start, inSameDayAs: now) ? "NEXT MEETING · \(time)" : "NEXT MEETING · TOMORROW \(time)"
    }

    /// A My targets row's detail and dot. `today` is "yyyy-MM-dd", local;
    /// `dueDate` is "yyyy-MM-dd" with an optional "THH:MM".
    package static func targetDetail(_ target: Target, today: String) -> (String, TodayItemTone) {
        let due = target.dueDate
        let dueDay = String(due.prefix(10))
        if !due.isEmpty, dueDay < today {
            return ("Overdue · \(shortDay(dueDay))", .overdue)
        }
        if !due.isEmpty, dueDay == today {
            let time = due.split(separator: "T", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            return (time.isEmpty ? "Due today" : "Due \(time)", .dueToday)
        }
        return ("In progress", .inProgress)
    }

    /// `now` as "yyyy-MM-dd" in `calendar`'s zone — `TargetQueries.todayDateString()`'s form.
    package static func dayString(_ now: Date, calendar: Calendar) -> String {
        format("yyyy-MM-dd", now, calendar)
    }

    // MARK: - Cards

    private static func waitingOnYou(_ data: HomeTodayData) -> TodayCard? {
        let count = data.awaitingCount + data.reminders.count
        guard count > 0 else { return nil }
        let actions = data.actions.map { action in
            (stamp: action.createdAt, item: TodayItem(
                chip: action.status == "failed" ? "Failed" : "Proposal",
                title: action.reason.isEmpty ? ReactionToolCatalog.title(for: action.tool) : action.reason,
                detail: nil, tone: nil, link: .inbox))
        }
        let reminders = data.reminders.map { reminder in
            (stamp: reminder.remindAt, item: TodayItem(
                chip: "Reminder", title: reminder.note.isEmpty ? "Reminder" : reminder.note,
                detail: nil, tone: nil, link: .inbox))
        }
        let items = (actions + reminders)
            .sorted { instant($0.stamp) > instant($1.stamp) }
            .prefix(itemLimit)
            .map(\.item)
        return TodayCard(kind: .waitingOnYou, eyebrow: "WAITING ON YOU · \(count)", items: items, link: .inbox)
    }

    private static func nextMeeting(_ data: HomeTodayData, now: Date, calendar: Calendar) -> TodayCard? {
        guard let event = data.nextEvent else { return nil }
        let delta = event.startDate.timeIntervalSince(now)
        guard delta >= 0, delta <= nextMeetingHorizon else { return nil }
        var line = ["\(format("HH:mm", event.startDate, calendar))–\(format("HH:mm", event.endDate, calendar))"]
        if let people = people(event.parsedAttendees) { line.append(people) }
        if data.nextEventHasPrep { line.append("Prep ready") }
        return TodayCard(
            kind: .nextMeeting, eyebrow: meetingEyebrow(start: event.startDate, now: now, calendar: calendar),
            title: event.title, body: line.joined(separator: " · "), link: .calendarEvent(id: event.id))
    }

    private static func briefing(_ data: HomeTodayData) -> TodayCard? {
        guard let briefing = data.briefing, let summary = briefingSummary(briefing) else { return nil }
        return TodayCard(kind: .briefing, eyebrow: "BRIEFING", body: summary, link: .briefing(id: briefing.id))
    }

    private static func myTargets(_ data: HomeTodayData, today: String) -> TodayCard? {
        guard !data.targets.isEmpty else { return nil }
        let items = data.targets.map { target in
            let (detail, tone) = targetDetail(target, today: today)
            return TodayItem(chip: nil, title: target.text, detail: detail, tone: tone, link: .target(id: target.id))
        }
        return TodayCard(kind: .myTargets, eyebrow: "MY TARGETS", items: items, link: .targets)
    }

    private static func agentsWaiting(_ data: HomeTodayData) -> TodayCard? {
        let rows = data.asks.rows
        guard !rows.isEmpty else { return nil }
        let items = rows.prefix(itemLimit).map { row in
            TodayItem(
                chip: row.ask.kind.rawValue.capitalized, title: row.ask.title, detail: row.workbenchName, tone: nil,
                link: .workbench(.forAsk(projectID: row.ask.projectID, sessionID: row.ask.sessionID, askID: row.ask.id)))
        }
        return TodayCard(kind: .agentsWaiting, eyebrow: "AGENTS WAITING · \(rows.count)", items: items,
                         link: .workbenches)
    }

    /// The Catch-Up badge's condition (`CatchUpQueries.hasUnacknowledgedReady`):
    /// the newest ready, unacknowledged recap — a newer one still building or
    /// failed does not hide it.
    private static func sinceYouWereAway(_ data: HomeTodayData, calendar: Calendar) -> TodayCard? {
        guard let recap = data.pendingRecap, recap.isReady, !recap.isAcknowledged else { return nil }
        let since = format("EEE HH:mm", Date(timeIntervalSince1970: recap.periodFrom), calendar).uppercased()
        return TodayCard(kind: .sinceYouWereAway, eyebrow: "SINCE YOU WERE AWAY · SINCE \(since)",
                         body: recap.tldr.isEmpty ? nil : recap.tldr, link: .catchUp)
    }

    // MARK: - Helpers

    /// Up to two attendee names (the email's local part when the name is
    /// blank) and "+N" for the rest; nil for no attendees.
    private static func people(_ attendees: [EventAttendee]) -> String? {
        guard !attendees.isEmpty else { return nil }
        let names = attendees.prefix(2).map { attendee in
            attendee.displayName.isEmpty
                ? String(attendee.email.split(separator: "@", maxSplits: 1).first ?? "")
                : attendee.displayName
        }
        let rest = attendees.count - names.count
        return names.joined(separator: ", ") + (rest > 0 ? " +\(rest)" : "")
    }

    /// "yyyy-MM-dd" → "MMM d"; the raw day when it does not parse.
    private static func shortDay(_ day: String) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: day) else { return day }
        fmt.dateFormat = "MMM d"
        return fmt.string(from: date)
    }

    /// An RFC 3339 UTC stamp as a date; an unparseable one sorts last.
    private static func instant(_ stamp: String) -> Date {
        ISO8601DateFormatter().date(from: stamp) ?? .distantPast
    }

    /// Gregorian (the POSIX locale's) in `calendar`'s zone, so "yyyy-MM-dd"
    /// matches the stored columns whatever calendar the owner uses.
    private static func format(_ pattern: String, _ date: Date, _ calendar: Calendar) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = pattern
        return fmt.string(from: date)
    }
}

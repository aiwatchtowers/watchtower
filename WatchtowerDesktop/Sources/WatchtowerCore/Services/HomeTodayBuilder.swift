import Foundation

/// Turns the Today read into Home's cards: each shows only with content, in
/// `TodayCardKind`'s fixed order, and only when the caller allows its kind.
/// Pure: no read, no clock of its own.
package enum HomeTodayBuilder {
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
            case .sinceYouWereAway: sinceYouWereAway(data, calendar: calendar)
            case .briefing: briefing(data)
            case .agentsWaiting: agentsWaiting(data)
            case .instructionSuggestion: instructionSuggestion(data)
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

    /// `now` as "yyyy-MM-dd" in `calendar`'s zone — `TargetQueries.todayDateString()`'s form.
    package static func dayString(_ now: Date, calendar: Calendar) -> String {
        format("yyyy-MM-dd", now, calendar)
    }

    // MARK: - Cards

    private static func briefing(_ data: HomeTodayData) -> TodayCard? {
        guard let briefing = data.briefing, let summary = briefingSummary(briefing) else { return nil }
        return TodayCard(kind: .briefing, eyebrow: "BRIEFING", body: summary, link: .briefing(id: briefing.id))
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

    /// The one open suggestion; Add / Dismiss act on it, the header opens Settings.
    private static func instructionSuggestion(_ data: HomeTodayData) -> TodayCard? {
        guard let suggestion = data.suggestion else { return nil }
        return TodayCard(
            kind: .instructionSuggestion, eyebrow: "INSTRUCTIONS",
            body: "You keep telling agents: \u{201C}\(suggestion.text)\u{201D} — add to your instructions?",
            link: .instructionSettings, suggestionID: suggestion.id)
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

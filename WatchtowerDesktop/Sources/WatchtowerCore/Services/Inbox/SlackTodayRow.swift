import Foundation

/// Slack today's row in the Inbox list (spec "The list": "the first two
/// lines of the artifact", "Built in · today · N messages", channels with
/// news on a neutral pill). Drawn from the state, so a quiet message never
/// changes it. Pure.
package enum SlackTodayRow {
    package static let title = "Slack today"

    /// Today: the top lines as `#<channel> — <text>`, one per line; nil
    /// summary or another day's: "Nothing yet today" under "Built in".
    package static func content(
        summary: SlackTodaySummary?,
        isUnread: Bool,
        changedAt: Date,
        now: Date,
        calendar: Calendar
    ) -> InboxRowContent {
        let time = InboxRowTime.label(changedAt, now: now, calendar: calendar)
        guard let summary, summary.isToday(now: now, calendar: calendar) else {
            return InboxRowContent(kind: .slackToday, title: title, preview: SlackTodayPaneText.nothingYet,
                                   meta: "Built in", time: time, isUnread: isUnread)
        }
        let lines = summary.topLines.map { "\(SlackTodaySummary.heading($0.channel)) — \($0.text)" }
        return InboxRowContent(
            kind: .slackToday, title: title,
            preview: lines.isEmpty ? "Nothing for you yet today" : lines.joined(separator: "\n"),
            meta: "Built in · today · \(SlackTodaySummary.plural(summary.messages, "message", "messages"))",
            time: time,
            pill: summary.newsChannels > 0 ? InboxRowPill(count: summary.newsChannels, tone: .batch) : nil,
            isUnread: isUnread)
    }
}

/// Slack today's reading pane texts. Pure.
package enum SlackTodayPaneText {
    package static let nothingYet = "Nothing yet today"
    package static let staleNoteText = "This is yesterday's list. Today's starts after the next sync."

    /// "Today · 900 messages in 46 conversations · 4 with news for you"; nil
    /// summary or another day's: "Nothing yet today".
    package static func subtitle(summary: SlackTodaySummary?, now: Date, calendar: Calendar) -> String {
        guard let summary, summary.isToday(now: now, calendar: calendar) else { return nothingYet }
        return "Today · \(SlackTodaySummary.plural(summary.messages, "message", "messages")) in "
            + "\(SlackTodaySummary.plural(summary.channels, "conversation", "conversations")) · "
            + "\(summary.newsChannels) with news for you"
    }

    /// The note over yesterday's list: the card was last written before
    /// today and the state is another day's — or unreadable (nil: an
    /// undecodable or unknown-version state), the card's date deciding. A
    /// card written today over an older state is today's empty card (a run
    /// after midnight that read nothing), not yesterday's list.
    package static func staleNote(
        summary: SlackTodaySummary?,
        writtenAt: Date,
        now: Date,
        calendar: Calendar
    ) -> String? {
        guard writtenAt < InboxToday.startOfToday(now: now, calendar: calendar) else { return nil }
        if let summary, summary.isToday(now: now, calendar: calendar) { return nil }
        return staleNoteText
    }
}

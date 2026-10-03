import Foundation

/// The strings of the Session view and of a session row's report line (spec
/// 2026-10-03-workbench-session-report Part 1, Part 7). Pure: times are
/// Go's UTC stamps shown in `timeZone`, so the tests pin it.
package enum SessionReportPresentation {
    package typealias Report = SessionReport

    // MARK: Empty texts

    package static let noSessionText = "Pick a session"
    package static let onYouEmptyText = "Nothing — the agent is not waiting for you."
    package static let nowEmptyText = "Nothing in progress."
    package static let prsEmptyText = "No pull requests yet."
    package static let phasesEmptyText = "No board tasks in this session yet."
    package static let lastWordEmptyText = "The agent has not finished yet."

    // MARK: State and size

    /// "14 / 15 tasks"; "No tasks yet" when nothing is in scope.
    package static func heroLine(_ progress: Report.Progress) -> String {
        guard progress.total > 0 else { return "No tasks yet" }
        return "\(progress.done) / \(progress.total) " + (progress.total == 1 ? "task" : "tasks")
    }

    /// The progress bar's fill, 0...1.
    package static func progressFraction(_ progress: Report.Progress) -> Double {
        guard progress.total > 0 else { return 0 }
        return min(1, max(0, Double(progress.done) / Double(progress.total)))
    }

    /// How long the session ran — created to finished, or to its last
    /// activity: "12m", "3h 20m", "4d 8h". Nil for an unreadable stamp.
    package static func ranFor(_ session: Report.Session) -> String? {
        let end = session.finishedAt.isEmpty ? session.lastActiveAt : session.finishedAt
        guard let from = TimeFormatting.parseISO(session.createdAt),
              let to = TimeFormatting.parseISO(end), to >= from else { return nil }
        let minutes = Int(to.timeIntervalSince(from) / 60)
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes / (24 * 60))d \(minutes / 60 % 24)h"
    }

    // MARK: Done

    package struct PhaseLine: Equatable, Sendable {
        package let title: String
        /// "7/7".
        package let count: String
        /// "Sep 29, 09:01 – 11:07"; nil before any of its leaves started.
        package let span: String?
        package let isComplete: Bool

        package init(title: String, count: String, span: String?, isComplete: Bool) {
            self.title = title
            self.count = count
            self.span = span
            self.isComplete = isComplete
        }
    }

    package static func phaseLine(_ phase: Report.Phase, timeZone: TimeZone = .current) -> PhaseLine {
        PhaseLine(
            title: phase.text,
            count: "\(phase.done)/\(phase.total)",
            span: timeSpan(from: phase.startedAt, to: phase.finishedAt, timeZone: timeZone),
            isComplete: !phase.finishedAt.isEmpty
        )
    }

    /// "Sep 29, 09:01 – 11:07" on one day, "Sep 29, 23:10 – Sep 30, 01:05"
    /// across midnight, "Oct 1, 07:47 – …" while still running. Nil when the
    /// start is missing or unreadable.
    package static func timeSpan(from start: String, to end: String, timeZone: TimeZone = .current) -> String? {
        guard let from = TimeFormatting.parseISO(start) else { return nil }
        let head = dayAndTime(from, timeZone)
        guard let to = TimeFormatting.parseISO(end) else { return "\(head) – …" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let tail = calendar.isDate(from, inSameDayAs: to) ? time(to, timeZone) : dayAndTime(to, timeZone)
        return "\(head) – \(tail)"
    }

    /// "Next: #423 Document the export".
    package static func nextLine(_ item: Report.Item) -> String {
        "Next: #\(item.id) \(item.text)"
    }

    // MARK: Now

    /// "in progress · feat/export-ui · since Oct 2, 10:15".
    package static func nowDetail(_ item: Report.NowItem, timeZone: TimeZone = .current) -> String {
        var parts = [statusLabel(item.status)]
        if !item.branch.isEmpty { parts.append(item.branch) }
        if let since = TimeFormatting.parseISO(item.since) {
            parts.append("since " + dayAndTime(since, timeZone))
        }
        return parts.joined(separator: " · ")
    }

    package static func statusLabel(_ status: String) -> String {
        status.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: Pull requests

    package struct PRLine: Equatable, Sendable {
        /// "PR #151 Export progress sheet", or the branch name.
        package let title: String
        /// "open · +180/−12", "merged Oct 2, 12:00 · +420/−35", "no PR yet",
        /// "not checked".
        package let detail: String

        package init(title: String, detail: String) {
            self.title = title
            self.detail = detail
        }
    }

    package static func prLine(_ pr: Report.PullRequest, timeZone: TimeZone = .current) -> PRLine {
        let title: String
        if let number = pr.prNumber {
            title = pr.title.isEmpty ? "PR #\(number)" : "PR #\(number) \(pr.title)"
        } else {
            title = pr.branch ?? pr.ref
        }
        var parts: [String] = []
        switch pr.state {
        case "merged":
            parts.append(TimeFormatting.parseISO(pr.mergedAt).map { "merged " + dayAndTime($0, timeZone) } ?? "merged")
        case "open", "closed":
            parts.append(pr.prNumber == nil ? "no PR yet" : pr.state)
        case "none":
            // gh checked the branch and found no PR.
            parts.append("no PR yet")
        default:
            // Never checked: a branch may still turn out to carry a PR (the
            // report lists it beside that PR until a refresh links them).
            parts.append("not checked")
        }
        if let additions = pr.additions, let deletions = pr.deletions {
            parts.append("+\(additions)/−\(deletions)")
        }
        return PRLine(title: title, detail: parts.joined(separator: " · "))
    }

    // MARK: Agent's last word

    package struct LastWord: Equatable, Sendable {
        /// "Agent's last word", or "Previous summary" once a new prompt
        /// cleared the finish but its summary is kept.
        package let title: String
        package let text: String
        /// `text` is the empty text, not the agent's words.
        package let isPlaceholder: Bool

        package init(title: String, text: String, isPlaceholder: Bool) {
            self.title = title
            self.text = text
            self.isPlaceholder = isPlaceholder
        }
    }

    package static func lastWord(_ session: Report.Session) -> LastWord {
        let summary = session.finishSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            return LastWord(title: "Agent's last word", text: lastWordEmptyText, isPlaceholder: true)
        }
        let title = session.finishedAt.isEmpty ? "Previous summary" : "Agent's last word"
        return LastWord(title: title, text: summary, isPlaceholder: false)
    }

    // MARK: Session rows

    /// The panel row's report line, "#314 · 14/15 · PR #147 open": the
    /// ticket, X/Y when anything is in scope, Go's PR line. A summary kept
    /// from an earlier run after a failed refresh ends in "· stale", so a
    /// failure never reads as a blank line; "" when there is nothing to say.
    package static func rowCaption(_ summary: SessionReportSummary, stale: Bool = false) -> String {
        var parts: [String] = []
        if let target = summary.targetID { parts.append("#\(target)") }
        if summary.total > 0 { parts.append("\(summary.done)/\(summary.total)") }
        if !summary.prLine.isEmpty { parts.append(summary.prLine) }
        if stale { parts.append("stale") }
        return parts.joined(separator: " · ")
    }

    // MARK: Formatting

    private static let hourMinute: Date.FormatString =
        "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)"

    private static func dayAndTime(_ date: Date, _ timeZone: TimeZone) -> String {
        "\(format(date, "\(month: .abbreviated) \(day: .defaultDigits)", timeZone)), \(time(date, timeZone))"
    }

    private static func time(_ date: Date, _ timeZone: TimeZone) -> String {
        format(date, hourMinute, timeZone)
    }

    private static func format(_ date: Date, _ format: Date.FormatString, _ timeZone: TimeZone) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: format,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: timeZone,
            calendar: Calendar(identifier: .gregorian)
        ))
    }
}

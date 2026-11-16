import Foundation

/// Every string of Settings → Profile → Watchman (spec
/// `docs/superpowers/specs/2026-11-16-watchman-design.md` §10, §11), pinned
/// by `WatchmanSettingsCopyTests`. Phase 1 is read-only except Start
/// Learning, Run Backtest Now and Retry.
package enum WatchmanSettingsCopy {
    package static let sectionTitle = "Watchman"

    // MARK: Workbenches not learned yet

    package static let workbenchesTitle = "Workbenches"
    package static let notLearnedIntro = "Watchman hasn't learned any workbench yet. It reads your past decisions "
        + "on a workbench before it can answer for you there; nothing acts until you hand it a session."
    package static let moreWorkbenchesIntro = "Watchman reads your past decisions on a workbench before it can "
        + "answer for you there; nothing acts until you hand it a session."
    package static let noWorkbenches = "No workbenches yet. Watchman learns from the sessions of a workbench."
    package static let startLearning = "Start Learning"
    package static let loading = "Reading Watchman's status…"
    package static let retry = "Retry"

    /// "~1 850 decisions · est. 1.6 M tokens".
    package static func estimateLine(_ estimate: WatchmanEstimate) -> String {
        "~\(count(estimate.decisions)) decisions · est. \(tokens(estimate.tokens)) tokens"
    }

    /// The busy line of a workbench that learns: "Learning… 340 of 1 850"
    /// (written capped at the estimate until learning is done).
    package static func learningLine(_ row: WatchmanWorkbenchStatus) -> String {
        if let learning = row.learning, learning.estimated > 0 {
            let written = learning.done ? learning.written : min(learning.written, learning.estimated)
            return "Learning… \(count(written)) of \(count(learning.estimated))"
        }
        if let estimate = row.estimate, estimate.decisions > 0 {
            return "Learning… 0 of \(count(estimate.decisions))"
        }
        return "Learning…"
    }

    package static func readFailed(_ message: String) -> String {
        "Couldn't read Watchman's status: \(message)"
    }

    package static func learnFailed(_ message: String) -> String {
        "Learning stopped: \(message). Watchman stays on; the daemon continues in its next cycles."
    }

    // MARK: Sleep window

    package static let sleepTitle = "Sleep window"
    package static let sleepCaption = "Learned from when you stop and start working on workbenches. Recomputed weekly."
    package static let sleepLearned = "Learned"
    package static let sleepPinned = "Pinned by you"
    package static let sleepNotLearned = "Not learned yet: Watchman needs a week of your activity."

    /// `"00:30-07:45"` → `"00:30–07:45"`; nil when not learned.
    package static func sleepValue(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: "-", with: "–")
    }

    // MARK: Backtest

    package static let backtestTitle = "Backtest"
    package static let columnCategory = "Category"
    package static let columnAgreement = "Agreement"
    package static let columnWrongHigh = "Wrong while sure"
    package static let columnRating = "Rating"
    package static let strong = "Strong"
    package static let weak = "Weak"
    package static let notMeasured = "Not measured"
    package static let noValue = "—"
    package static let barNote = "Strong: 80 % agreement or more and 5 % or less wrong while sure. "
        + "Below that Watchman marks every night decision unsure. Under 30 decisions: not measured."
    package static let runBacktest = "Run Backtest Now"
    package static let runningButton = "Running…"
    package static let neverRun = "Watchman hasn't checked itself yet. The backtest hides your latest decisions "
        + "and asks Watchman to take them; nothing acts until you've seen the numbers."
    package static let busy = "A backtest is already running — this section updates when it finishes."

    /// The eight v1 categories in the table's order (spec §8.2).
    package static let categories = ["design", "scope", "ux_text", "tests", "review_code", "review_doc",
                                     "permission", "finish"]

    /// "Backtest" or, with several learned workbenches, "Backtest · acme-api".
    package static func backtestTitle(name: String, several: Bool) -> String {
        several ? "\(backtestTitle) · \(name)" : backtestTitle
    }

    package static func sleepTitle(name: String, several: Bool) -> String {
        several ? "\(sleepTitle) · \(name)" : sleepTitle
    }

    /// "Last run 15 Nov, 03:12 · your latest 30 decisions per category, …".
    package static func lastRunCaption(_ backtest: WatchmanBacktest, timeZone: TimeZone = .current) -> String {
        let when = date(backtest.startedAt).map { stamp($0, "d MMM, HH:mm", timeZone) }
        let head = when.map { "Last run \($0) · your" } ?? "Your"
        return "\(head) latest 30 decisions per category, hidden and decided again by Watchman."
    }

    /// "Last results, 15 Nov" above the previous table while a run is going
    /// or after one failed.
    package static func lastResults(_ backtest: WatchmanBacktest, timeZone: TimeZone = .current) -> String {
        guard let when = date(backtest.finishedAt ?? backtest.startedAt) else { return "Last results" }
        return "Last results, \(stamp(when, "d MMM", timeZone))"
    }

    /// "Backtest running · ux_text, 18 of 30 · 3 of 8 categories done".
    package static func runningLine(_ progress: String) -> String {
        progress.isEmpty ? "Backtest running · starting" : "Backtest running · \(progress)"
    }

    /// The share of the run done, read from the progress line
    /// (`"<category>, <i> of <n> · <k> of 8 categories done"`); nil when the
    /// line has another shape (the bar then spins).
    package static func progressFraction(_ progress: String) -> Double? {
        let numbers = progress.split { !$0.isNumber }.compactMap { Int($0) }
        guard numbers.count >= 4, numbers[1] > 0, numbers[3] > 0 else { return nil }
        let (item, items, done, total) = (numbers[0], numbers[1], numbers[2], numbers[3])
        return min(1, (Double(done) + Double(item) / Double(items)) / Double(total))
    }

    /// The failed or interrupted run's line; the last results stay below it.
    package static func failedLine(_ message: String, hasResults: Bool) -> String {
        let reason = message.isEmpty || message == "interrupted" ? "it was interrupted" : message
        let tail = hasResults ? "Nothing changed; the last results stay." : "Nothing changed."
        return "The backtest stopped: \(trimmedSentence(reason)). \(tail)"
    }

    package static func analyticsOffNote(name: String) -> String {
        "Agent analytics is off on \(name), so your typed corrections there are not used."
    }

    package static func agreement(_ row: WatchmanBacktestCategory) -> String {
        measured(row) ? percent(row.agree, of: row.total) : noValue
    }

    package static func wrongHigh(_ row: WatchmanBacktestCategory) -> String {
        measured(row) ? percent(row.wrongHigh, of: row.total) : noValue
    }

    package static func rating(_ row: WatchmanBacktestCategory) -> String {
        switch row.status {
        case "strong": strong
        case "weak": weak
        default: notMeasured
        }
    }

    /// The rows in the table's order; a category the run did not report
    /// shows as not measured.
    package static func tableRows(_ backtest: WatchmanBacktest) -> [WatchmanBacktestCategory] {
        let byName = Dictionary(backtest.categories.map { ($0.category, $0) }) { first, _ in first }
        let known = categories.map {
            byName[$0] ?? WatchmanBacktestCategory(category: $0, total: 0, agree: 0, wrongHigh: 0, costUSD: 0,
                                                   status: "not_measured")
        }
        let extra = backtest.categories.filter { !categories.contains($0.category) }
        return known + extra
    }

    // MARK: Formatting

    /// Thousands grouped with a space: 1850 → "1 850".
    package static func count(_ value: Int) -> String {
        let digits = String(abs(value))
        var groups: [Substring] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            groups.insert(digits[start..<end], at: 0)
            end = start
        }
        return (value < 0 ? "-" : "") + groups.joined(separator: " ")
    }

    /// 1 600 000 → "1.6 M", 500 000 → "0.5 M", 12 000 → "12 k".
    package static func tokens(_ value: Int) -> String {
        if value >= 50_000 { return String(format: "%.1f M", Double(value) / 1_000_000) }
        if value >= 1_000 { return "\(value / 1_000) k" }
        return "\(value)"
    }

    private static func measured(_ row: WatchmanBacktestCategory) -> Bool {
        row.status != "not_measured" && row.total > 0
    }

    private static func percent(_ part: Int, of total: Int) -> String {
        "\(Int((Double(part) * 100 / Double(total)).rounded())) %"
    }

    private static func trimmedSentence(_ text: String) -> String {
        var line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        while line.hasSuffix(".") { line.removeLast() }
        return line
    }

    private static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        if let value = plain.date(from: text) { return value }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private static func stamp(_ date: Date, _ format: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

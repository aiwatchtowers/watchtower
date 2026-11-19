import Foundation

/// Every string of Settings → Profile → Watchman (spec
/// `docs/superpowers/specs/2026-11-16-watchman-design.md` §10, §11), pinned
/// by `WatchmanSettingsCopyTests`. Phase 2 adds editing: profile texts and
/// the sleep window (Edit / Unpin) and the owner's hard limits.
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

    /// A workbench whose commits could not be counted in time has no estimate.
    package static let estimateUnavailable = "Couldn't count its decisions in time (a large repository)."

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

    package static func refreshFailed(_ message: String) -> String {
        "Couldn't refresh Watchman's status: \(message). Showing the last one read."
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

    package static let sleepPlaceholder = "00:30-07:45"
    package static let sleepPinnedNote = "Saving pins the window: the weekly recompute leaves it until you unpin it."
    package static let sleepBadFormat = "Write the window as HH:MM-HH:MM on a 24-hour clock, e.g. 00:30-07:45."

    // MARK: Editing (phase 2)

    package static let edit = "Edit"
    package static let unpin = "Unpin"
    package static let save = "Save"
    package static let cancel = "Cancel"
    package static let remove = "Remove"
    package static let add = "Add"
    /// The mark before each line of a category's text.
    package static let bullet = "•"

    /// "Couldn't save: <the CLI's error>".
    package static func saveFailed(_ message: String) -> String { "Couldn't save: \(message)" }
    package static func unpinFailed(_ message: String) -> String { "Couldn't unpin: \(message)" }
    package static func addFailed(_ message: String) -> String { "Couldn't add the limit: \(message)" }
    package static func removeFailed(_ message: String) -> String { "Couldn't remove the limit: \(message)" }

    // MARK: Profile

    package static let profileTitle = "What Watchman learned"
    package static let profileCaption = "Your rules per category, distilled weekly from your decisions. An edit pins "
        + "the text until you unpin it."
    package static let profileEmpty = "No rules yet: a category needs at least 5 learned decisions. "
        + "They are rebuilt weekly."
    package static let profilePinned = "Pinned by you"
    package static let profilePinnedNote = "Saving pins this text: the weekly rebuild leaves it until you unpin it."
    package static let profileEmptyText = "Write at least one rule line."
    package static let profileLoading = "Reading what Watchman learned…"

    package static func profileTitle(name: String, several: Bool) -> String {
        several ? "\(profileTitle) · \(name)" : profileTitle
    }

    /// "Learned 14 Nov" beside an entry the weekly rebuild wrote.
    package static func profileLearned(_ updatedAt: String, timeZone: TimeZone = .current) -> String {
        guard let when = date(updatedAt) else { return "Learned" }
        return "Learned \(stamp(when, "d MMM", timeZone))"
    }

    package static func profileTooLong(lines: Int) -> String {
        "At most \(WatchmanProfileEntry.maxLines) lines; this text has \(lines)."
    }

    package static func profileReadFailed(_ message: String) -> String {
        "Couldn't read what Watchman learned: \(message)"
    }

    // MARK: Hard limits

    package static let limitsTitle = "Your hard limits"
    package static let limitsCaption = "Watchman parks these for you in every mode. "
        + "The built-in ones can't be removed; you can add your own."
    /// How many built-in rows the one line names before "…".
    package static let builtinShown = 4

    /// The built-in rows on one line: "Built in: A, B, C, D… (12)"; the
    /// full list is `builtinHelp`.
    package static func builtinSummary(_ names: [String]) -> String {
        let shown = names.prefix(builtinShown).map(builtinLimit).joined(separator: ", ")
        let more = names.count > builtinShown ? "…" : ""
        return "Built in: \(shown)\(more) (\(names.count))"
    }

    /// Every built-in row, one per line (the summary line's tooltip).
    package static func builtinHelp(_ names: [String]) -> String {
        names.map(builtinLimit).joined(separator: "\n")
    }

    /// The confirmation before **Remove**.
    package static func removeConfirmTitle(_ pattern: String) -> String { "Remove the limit “\(pattern)”?" }
    package static let removeConfirmMessage = "Watchman may then take this action for you while it holds a session."
    package static let addLimit = "Add a Limit…"
    package static let limitKindTitle = "Kind"
    package static let limitEmptyPattern = "Write the command's first words or the tool's name."
    package static let limitOneLine = "The pattern must be one line."
    package static let limitToolBlanks = "A tool name has no spaces."

    package static func limitsReadFailed(_ message: String) -> String { "Couldn't read the limits: \(message)" }

    package static func limitKind(_ kind: WatchmanLimitKind) -> String {
        switch kind {
        case .command: "Command"
        case .tool: "Tool"
        }
    }

    package static func limitPlaceholder(_ kind: WatchmanLimitKind) -> String {
        switch kind {
        case .command: "terraform apply"
        case .tool: "create_jira_issue"
        }
    }

    package static func limitHint(_ kind: WatchmanLimitKind) -> String {
        switch kind {
        case .command: "Parks every shell command that starts with these words."
        case .tool: "Parks the tool of this name, also as an MCP tool."
        }
    }

    /// A built-in row's line (`watchman.HardLimit` names); an unknown name
    /// from a newer CLI shows as it is.
    package static func builtinLimit(_ name: String) -> String {
        switch name {
        case "unreadable": "A command that cannot be read"
        case "send_pack": "A plumbing push (git send-pack)"
        case "main_ref": "Push to or merge into the default branch"
        case "tag": "Create, delete or push a tag"
        case "release": "A GitHub release"
        case "testflight": "An App Store Connect or TestFlight upload"
        case "force_push": "A forced push"
        case "reset_shared": "A forced move of a shared branch"
        case "delete_outside": "Delete outside the session's worktrees"
        case "outward": "A message or comment other people see"
        case "standing_grant": "Change the agent's own permission settings"
        case "outside_folder": "Edit a file outside the workbench folder and its worktrees"
        default: name
        }
    }

    // MARK: Backtest

    package static let backtestTitle = "Backtest"
    package static let columnCategory = "Category"
    package static let columnAgreement = "Agreement"
    package static let columnWrongHigh = "Bad while sure"
    package static let handedHeader = "Handed"
    package static let columnRating = "Rating"
    package static let strong = "Strong"
    package static let weak = "Weak"
    package static let notMeasured = "Not measured"
    package static let noValue = "—"
    package static let barNote = "Strong: 5 % or less of its decisions bad (ones you would have had to undo) "
        + "and none bad while sure; a different but reasonable decision does not count against it. "
        + "Below that Watchman marks every night decision unsure. "
        + "Under 30 decisions, or fewer than 20 left after the ones handed to you: not measured."
    package static let runBacktest = "Run Backtest Now"
    package static let runningButton = "Running…"
    package static let neverRun = "Watchman hasn't checked itself yet. The backtest hides your latest decisions "
        + "and asks Watchman to take them; nothing acts until you've seen the numbers."
    package static let busy = "A backtest is already running — this section updates when it finishes."

    /// A not-measured row whose decisions were mostly handed to the owner.
    package static func notMeasuredHanded(handed: Int) -> String {
        "Not measured: \(handed) of 30 handed to you"
    }

    /// The workbench's line while the relabel pass runs.
    package static func relabelling(left: Int) -> String {
        "Sorting earlier decisions: \(count(left)) left · the backtest runs after it"
    }

    /// The Handed cell: the count, or a dash when nothing was handed.
    package static func handedCell(_ row: WatchmanBacktestCategory) -> String {
        row.handed > 0 ? "\(row.handed)" : noValue
    }

    /// Under a not-measured row whose decisions were handed to the owner; nil otherwise.
    package static func handedNote(_ row: WatchmanBacktestCategory) -> String? {
        row.status == "not_measured" && row.handed > 0 ? notMeasuredHanded(handed: row.handed) : nil
    }

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

    /// "base rate 67 %" under a measured category: what always giving the
    /// owner's most common answer would score (informational); nil when the
    /// category is not measured.
    package static func baseRate(_ row: WatchmanBacktestCategory) -> String? {
        measured(row) ? "base rate \(Int((row.baseline * 100).rounded())) %" : nil
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

    /// Whole thousands below a million, one decimal above:
    /// 1 600 000 → "1.6 M", 500 000 → "500 k", 1 750 → "2 k", 900 → "900".
    package static func tokens(_ value: Int) -> String {
        let thousands = Int((Double(value) / 1_000).rounded())
        if thousands >= 1_000 { return String(format: "%.1f M", Double(value) / 1_000_000) }
        if value >= 1_000 { return "\(thousands) k" }
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

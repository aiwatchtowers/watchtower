import Foundation
import WatchtowerCore

/// The pane's strings.
enum AgentAnalyticsFormat {
    /// "14h 20m", "31h", "27m", "45s".
    static func duration(_ ms: Int64) -> String {
        let seconds = max(ms, 0) / 1000
        let hours = seconds / 3600, minutes = seconds % 3600 / 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    static func cost(_ usd: Double) -> String { String(format: "$%.2f", usd) }

    static func percent(_ part: Double, of whole: Double) -> String {
        guard whole > 0 else { return "0%" }
        return "\(Int((part / whole * 100).rounded()))%"
    }

    /// A part's share of a whole: "46%", `<1%` for anything above zero but
    /// under one percent (never "0%"), "0%" only for none.
    static func share(_ part: Int64, of total: Int64) -> String {
        guard part > 0, total > 0 else { return "0%" }
        return share(Double(part) / Double(total))
    }

    /// The same for a fraction the report already computed (0...1).
    static func share(_ fraction: Double) -> String {
        guard fraction > 0 else { return "0%" }
        let percent = fraction * 100
        return percent < 1 ? "<1%" : "\(Int(percent.rounded()))%"
    }

    /// A tool's name as the owner reads it: `mcp__watchtower-workbench__get_ask`
    /// is "Watchtower: get_ask", another server's `mcp__<server>__<tool>` is
    /// "<server>: <tool>"; anything else as sent.
    static func toolName(_ raw: String) -> String {
        guard raw.hasPrefix("mcp__") else { return raw }
        let rest = raw.dropFirst("mcp__".count)
        guard let split = rest.range(of: "__") else { return raw }
        let server = String(rest[..<split.lowerBound]), tool = String(rest[split.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return raw }
        let isWatchtower = server == "watchtower" || server.hasPrefix("watchtower-")
        return "\(isWatchtower ? "Watchtower" : server): \(tool)"
    }

    /// The first `keep` rows and the rest.
    static func fold<T>(_ rows: [T], keep: Int) -> (shown: [T], rest: [T]) {
        let count = max(keep, 0)
        return (Array(rows.prefix(count)), Array(rows.dropFirst(count)))
    }

    /// Cache reads over all input the model read (fresh, cache reads and
    /// cache writes; output left out): "28%", "—" with no input.
    static func cacheHit(_ tokens: AgentTokens) -> String {
        let input = tokens.input + tokens.cacheRead + tokens.cacheWrite5m + tokens.cacheWrite1h
        guard input > 0 else { return "—" }
        return percent(Double(tokens.cacheRead), of: Double(input))
    }

    /// A baseline part's name (`internal/agentlog/claude.go`); an unknown
    /// one (a newer CLI) as sent.
    static func label(part raw: String) -> String {
        [
            "instructions": "CLAUDE.md & rules", "skills": "Skill list", "tools": "Tool schemas",
            "system": "System prompt", "deferred_tools": "Deferred tools", "agents": "Agent list",
            "mcp": "MCP instructions", "hooks": "Hooks", "other": "Other"
        ][raw] ?? raw
    }

    /// A context growth source's name (`internal/agentreport/context.go`):
    /// a tool name as sent, `owner`/`model`/`reminders` named.
    static func label(growthSource raw: String) -> String {
        [
            "owner": "Your turns", "model": "Model output", "reminders": "System reminders & other"
        ][raw] ?? toolName(raw)
    }

    /// An error class's name (`internal/agentlog/claude_tools.go`); an
    /// unknown one as sent.
    static func label(errorClass raw: String) -> String {
        [
            "exit_code": "Command failed", "not_found": "File not found", "timeout": "Timed out",
            "edit_no_match": "Edit text not found", "edit_multi_match": "Edit text not unique",
            "stale_read": "File changed since read", "too_large": "Output too large",
            "input_invalid": "Invalid input", "no_such_tool": "Unknown tool", "unknown_agent": "Unknown agent type",
            "isolation_block": "Blocked by worktree isolation", "sleep_blocked": "Sleep blocked",
            "agent_limit": "Agent limit", "429": "Rate limited", "other": "Other"
        ][raw] ?? raw
    }

    /// A denial kind's name (`internal/agentreport/trouble.go`); an unknown
    /// one as sent.
    static func label(denial raw: String) -> String {
        [
            "permission-rule": "Permission rule", "user-rejected": "You declined",
            "automode-blocked": "Blocked in auto mode", "automode-unavailable": "Auto mode unavailable"
        ][raw] ?? raw
    }

    /// "950", "12.3k", "2.5M".
    static func tokens(_ count: Int64) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1000 { return String(format: "%.1fk", Double(count) / 1000) }
        return "\(count)"
    }

    /// What Discuss in Chat puts in the composer: the period's figures and
    /// its top three hints with their actions, as the report words them.
    static func discussText(_ overview: AgentReportOverview) -> String {
        let totals = overview.totals
        var lines = [
            "Help me act on the agent analytics of this workbench (\(periodLabel(overview))): "
                + "\(totals.sessions) sessions, \(cost(totals.costUSD)), active \(duration(totals.activeMS)), "
                + "cache hit \(cacheHit(totals.tokens))."
        ]
        let top = overview.hints.prefix(3)
        if top.isEmpty {
            lines.append("The report has no hints for this period.")
        } else {
            lines.append("What would save the most:")
            for (index, hint) in top.enumerated() {
                lines.append("\(index + 1). \(hint.finding)")
                if let action = hint.action, !action.isEmpty { lines.append("   \(action)") }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// "Loading history — 1,234 files so far" until the import is done; nil
    /// then. Before the one-time move no scan runs, so the line says what
    /// unblocks it instead (`isImportWarning`). The count follows `locale`
    /// (the owner's, like the pane's other numbers).
    static func importLine(_ importState: AgentImportState, locale: Locale = .autoupdatingCurrent) -> String? {
        guard importState.state != "done" else { return nil }
        if isImportWarning(importState) {
            return "History not moved yet — restart the daemon or run watchtower agents scan"
        }
        let files = importState.filesStored.formatted(.number.locale(locale))
        return "Loading history — \(files) files so far"
    }

    /// The import is stuck until the move out of watchtower.db succeeds.
    static func isImportWarning(_ importState: AgentImportState) -> Bool {
        importState.state == "waiting_for_move"
    }

    /// The period the report covers, from its own `since`/`until`; nil
    /// when it matches none of the picker's.
    static func period(of overview: AgentReportOverview) -> AgentAnalyticsCenter.Period? {
        if overview.since.isEmpty { return nil }
        guard let since = reportDate(overview.since), let until = reportDate(overview.until) else { return nil }
        return AgentAnalyticsCenter.Period(rawValue: Int((until.timeIntervalSince(since) / 86400).rounded()))
    }

    /// "Oct 1 – Oct 8", or "All history to Oct 8".
    static func periodLabel(_ overview: AgentReportOverview, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d"
        let until = reportDate(overview.until).map(formatter.string(from:)) ?? overview.until
        guard !overview.since.isEmpty else { return "All history to \(until)" }
        let since = reportDate(overview.since).map(formatter.string(from:)) ?? overview.since
        return "\(since) – \(until)"
    }

    /// The window of the same length right before the report's ("Oct 14 – Oct 21"); nil for no start.
    static func previousPeriodLabel(_ overview: AgentReportOverview, timeZone: TimeZone = .current) -> String? {
        guard !overview.since.isEmpty, let since = reportDate(overview.since),
              let until = reportDate(overview.until) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d"
        let start = since.addingTimeInterval(-until.timeIntervalSince(since))
        return "\(formatter.string(from: start)) – \(formatter.string(from: since))"
    }

    /// "Oct 1, 10:00" in local time.
    static func moment(_ raw: String) -> String {
        guard let value = reportDate(raw) else { return raw }
        return value.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// The report's RFC 3339 times, with or without fractional seconds.
    static func reportDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: raw) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

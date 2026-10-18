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

    static func subagentsLine(_ subagents: AgentSubagents) -> String {
        guard subagents.count >= 1 else { return "Subagents: none" }
        return "Subagents: \(String(format: "%.1f", subagents.avgParallel)) at once on average · peak \(subagents.peak)"
    }

    /// "Loading history — 2,125 files so far" until the import is done; nil then.
    static func importLine(_ importState: AgentImportState) -> String? {
        guard importState.state != "done" else { return nil }
        let files = importState.filesStored.formatted(.number.locale(Locale(identifier: "en_US")))
        return "Loading history — \(files) files so far"
    }

    /// The period the report covers, from its own `since`/`until`; nil
    /// when it matches none of the picker's.
    static func period(of overview: AgentReportOverview) -> AgentAnalyticsCenter.Period? {
        if overview.since.isEmpty { return .all }
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

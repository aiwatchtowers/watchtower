import Foundation

/// What the Usage → Watchtower tab shows for one `usage llm` read: which
/// state, and every piece of text. Pure, so the Core tests pin it.
package enum LLMUsageScreen: Equatable {
    /// The first read of this period has not answered yet.
    case loading
    /// The ledger has no row yet ("Recording starts with the next AI call").
    case emptyLedger
    /// No report to show: the error class is the subtitle.
    case failed(LLMUsageLoadError)
    /// The report; `recordingSince` while the ledger is younger than the
    /// period, `refreshFailedAt` (the last good read) when the latest refresh failed.
    case report(LLMUsageReport, recordingSince: String?, refreshFailedAt: Date?)
}

package enum LLMUsagePresentation {
    // MARK: - State

    package static func screen(
        report: LLMUsageReport?,
        error: LLMUsageLoadError?,
        lastUpdated: Date?,
        period: LLMUsagePeriod,
        now: Date,
        calendar: Calendar = .current
    ) -> LLMUsageScreen {
        guard let report else { return error.map(LLMUsageScreen.failed) ?? .loading }
        guard let since = parseDate(report.ledgerSince) else { return .emptyLedger }
        let caption = since > period.start(now: now, calendar: calendar)
            ? "Recording since \(since.formatted(date: .abbreviated, time: .shortened))"
            : nil
        return .report(report, recordingSince: caption, refreshFailedAt: error == nil ? nil : lastUpdated)
    }

    /// RFC 3339 with or without fractional seconds; nil for "" or junk.
    static func parseDate(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// The layout's shape behind `.redacted(reason: .placeholder)` while the
    /// first read runs: no real numbers.
    package static let placeholder: LLMUsageReport = {
        var totals = LLMUsageTotals.zero
        totals.calls = 1000
        totals.input = 100_000
        totals.cacheRead = 1_000_000
        totals.output = 100_000
        totals.costUSD = 10
        let rows = ["digest.channel", "briefing.daily", "ideas.consolidate", "media.describe"].map {
            LLMUsagePurposeRow(purpose: $0, calls: 100, input: 100_000, output: 10000, costUSD: 1, perCallTokens: 1000)
        }
        return LLMUsageReport(
            chats: totals, pageTotal: totals,
            watchtower: LLMUsageWatchtower(totals: totals, rows: rows),
            workbenches: LLMUsageWorkbenches(totals: totals, sessions: totals, helpers: totals)
        )
    }()

    // MARK: - Numbers

    /// `$x.xx`, `≈ $x.xx` for an estimate, `≥ $x.xx` for a lower bound, `—`
    /// when nothing in it could be priced.
    package static func cost(_ usd: Double?, isEstimate: Bool, isLowerBound: Bool) -> String {
        guard let usd, !(isLowerBound && usd == 0) else { return "—" }
        let amount = String(format: "$%.2f", usd)
        if isLowerBound { return "≥ \(amount)" }
        if isEstimate { return "≈ \(amount)" }
        return amount
    }

    package static func cost(_ totals: LLMUsageTotals) -> String {
        cost(totals.costUSD, isEstimate: totals.costIsEstimate, isLowerBound: totals.costIsLowerBound)
    }

    /// "512", "7.5 K", "212 K", "9.4 M", "412 M": one decimal under ten, none above.
    package static func tokens(_ count: Int64) -> String {
        guard count >= 1000 else { return "\(count)" }
        let thousands = Double(count) / 1000
        if rounded(thousands) < 1000 { return "\(short(thousands)) K" }
        return "\(short(Double(count) / 1_000_000)) M"
    }

    private static func rounded(_ value: Double) -> Double {
        value < 10 ? (value * 10).rounded() / 10 : value.rounded()
    }

    private static func short(_ value: Double) -> String {
        let text = value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    package static func calls(_ count: Int64) -> String { count.formatted(.number) }

    // MARK: - Totals gaps

    package struct Gap: Equatable, Sendable {
        package let text: String
        /// Untagged calls read in the warning colour.
        package let isWarning: Bool

        package init(text: String, isWarning: Bool) {
            self.text = text
            self.isWarning = isWarning
        }
    }

    /// The grey line under the totals: only the parts that are not zero.
    package static func gaps(_ totals: LLMUsageTotals) -> [Gap] {
        var parts: [Gap] = []
        if totals.estimatedCalls > 0 {
            parts.append(Gap(text: "\(callCount(totals.estimatedCalls)) with estimated usage", isWarning: false))
        }
        if totals.noPriceCalls > 0 {
            parts.append(Gap(text: "\(callCount(totals.noPriceCalls)) without a price (Codex/Ollama)", isWarning: false))
        }
        if totals.untaggedCalls > 0 {
            let noun = totals.untaggedCalls == 1 ? "call" : "calls"
            parts.append(Gap(text: "\(calls(totals.untaggedCalls)) untagged \(noun)", isWarning: true))
        }
        return parts
    }

    private static func callCount(_ count: Int64) -> String {
        "\(calls(count)) \(count == 1 ? "call" : "calls")"
    }

    // MARK: - Order

    /// By cost, highest first; rows nobody could price after them by
    /// tokens; untagged rows always last.
    package static func sorted(_ rows: [LLMUsagePurposeRow]) -> [LLMUsagePurposeRow] {
        rows.sorted { lhs, rhs in
            if lhs.isUntagged != rhs.isUntagged { return !lhs.isUntagged }
            return before(lhs.costUSD, lhs.tokens, rhs.costUSD, rhs.tokens)
        }
    }

    package static func sorted(_ rows: [LLMUsageAutomationRow]) -> [LLMUsageAutomationRow] {
        rows.sorted { before($0.costUSD, $0.tokens, $1.costUSD, $1.tokens) }
    }

    private static func before(_ lCost: Double?, _ lTokens: Int64, _ rCost: Double?, _ rTokens: Int64) -> Bool {
        switch (lCost, rCost) {
        case let (lhs?, rhs?) where lhs != rhs: lhs > rhs
        case (.some, nil): true
        case (nil, .some): false
        default: lTokens > rTokens
        }
    }

    // MARK: - Chats and workbenches

    package static func workbenchDetail(_ workbenches: LLMUsageWorkbenches) -> String {
        "sessions \(tokens(workbenches.sessions.tokens)) · Watchtower helpers \(tokens(workbenches.helpers.tokens))"
    }

    package static func analyticsOffNote(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let whose = names.count == 1 ? "its" : "their"
        return "Agent analytics is off for: \(names.joined(separator: ", ")) — \(whose) sessions are not counted."
    }

    package static func refreshFailedCaption(_ lastUpdated: Date) -> String {
        "Last updated \(lastUpdated.formatted(date: .omitted, time: .shortened)) — refresh failed"
    }

    // MARK: - Home

    package static let homeAISpendTooltip = "Watchtower, your automations and chats — workbenches are on Usage → Watchtower"
    package static let homeAISpendUnavailable = "AI spend unavailable"

    /// Home's "AI spend today": the report's `page_total` with the tab's
    /// marks, or "—" with "AI spend unavailable" while the first read runs and
    /// whenever the latest read failed (never $0, never a stale number).
    package static func homeAISpend(report: LLMUsageReport?, error: LLMUsageLoadError?) -> HomeAISpend {
        guard let report, error == nil else { return .unavailable }
        return HomeAISpend(value: cost(report.pageTotal), tooltip: homeAISpendTooltip)
    }
}

/// The text of Home's AI spend cell.
package struct HomeAISpend: Equatable, Sendable {
    package let value: String
    package let tooltip: String

    package init(value: String, tooltip: String) {
        self.value = value
        self.tooltip = tooltip
    }

    /// Before the first read: "—".
    package static let unavailable = Self(value: "—", tooltip: LLMUsagePresentation.homeAISpendUnavailable)
}

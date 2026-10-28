import Foundation

/// What `watchtower usage llm --json` prints (LLM usage ledger,
/// `docs/superpowers/specs/2026-10-27-llm-usage-ledger-design.md` §5). Mirrors
/// `cmd/usage_llm.go`, whose top-level keys are pinned by
/// `TestUsageLLM_JSONKeysPinned`. Nil Go slices arrive as `null` and decode
/// as empty; a cost nobody could price is `null` or absent.
package struct LLMUsageReport: Decodable, Equatable, Sendable {
    package var chats: LLMUsageTotals
    /// RFC 3339 time of the ledger's first row; "" while it is empty.
    package var ledgerSince: String
    package var ownAutomations: LLMUsageAutomations
    /// Watchtower + your automations + chats (what Home shows).
    package var pageTotal: LLMUsageTotals
    /// "today", "7d" or "30d".
    package var period: String
    package var watchtower: LLMUsageWatchtower
    package var workbenches: LLMUsageWorkbenches

    package init(
        chats: LLMUsageTotals = .zero,
        ledgerSince: String = "",
        ownAutomations: LLMUsageAutomations = .init(),
        pageTotal: LLMUsageTotals = .zero,
        period: String = "",
        watchtower: LLMUsageWatchtower = .init(),
        workbenches: LLMUsageWorkbenches = .init()
    ) {
        self.chats = chats
        self.ledgerSince = ledgerSince
        self.ownAutomations = ownAutomations
        self.pageTotal = pageTotal
        self.period = period
        self.watchtower = watchtower
        self.workbenches = workbenches
    }

    enum CodingKeys: String, CodingKey {
        case chats, period, watchtower, workbenches
        case ledgerSince = "ledger_since", ownAutomations = "own_automations", pageTotal = "page_total"
    }
}

/// One total: calls, the token split and the cost. The ledger's sections
/// carry every key; the workbench `sessions` total comes from agent
/// analytics and has no gap counts (and a `sessions` count of its own), so a
/// count that is absent reads 0.
package struct LLMUsageTotals: Decodable, Equatable, Sendable {
    package var calls: Int64 = 0
    package var errors: Int64 = 0
    /// Calls whose token counts were estimated (the provider reported none).
    package var estimatedCalls: Int64 = 0
    /// Calls with no price for their model (Codex/Ollama).
    package var noPriceCalls: Int64 = 0
    package var untaggedCalls: Int64 = 0
    package var input: Int64 = 0
    package var cacheRead: Int64 = 0
    package var cacheWrite: Int64 = 0
    package var output: Int64 = 0
    package var costUSD: Double?
    /// Some call in the total had no cost: the cost is at least this much.
    package var costIsLowerBound = false
    /// Some cost in the total is an estimate, not a reported cost; false when absent.
    package var costIsEstimate = false
    /// Agent sessions (workbench `sessions` only).
    package var sessions: Int64 = 0

    package static let zero = Self()

    package var tokens: Int64 { input + cacheRead + cacheWrite + output }

    package init() {}

    enum CodingKeys: String, CodingKey {
        case calls, errors, input, output, sessions
        case estimatedCalls = "estimated_calls", noPriceCalls = "no_price_calls", untaggedCalls = "untagged_calls"
        case cacheRead = "cache_read", cacheWrite = "cache_write", costUSD = "cost_usd"
        case costIsLowerBound = "cost_is_lower_bound", costIsEstimate = "cost_is_estimate"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) throws -> Int64 { try c.decodeIfPresent(Int64.self, forKey: key) ?? 0 }
        calls = try count(.calls)
        errors = try count(.errors)
        estimatedCalls = try count(.estimatedCalls)
        noPriceCalls = try count(.noPriceCalls)
        untaggedCalls = try count(.untaggedCalls)
        input = try count(.input)
        cacheRead = try count(.cacheRead)
        cacheWrite = try count(.cacheWrite)
        output = try count(.output)
        sessions = try count(.sessions)
        costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD)
        costIsLowerBound = try c.decodeIfPresent(Bool.self, forKey: .costIsLowerBound) ?? false
        costIsEstimate = try c.decodeIfPresent(Bool.self, forKey: .costIsEstimate) ?? false
    }
}

/// "Watchtower collecting and processing": Watchtower's own work, built-in
/// automations included, one row per purpose.
package struct LLMUsageWatchtower: Decodable, Equatable, Sendable {
    package var totals: LLMUsageTotals
    package var rows: [LLMUsagePurposeRow]

    package init(totals: LLMUsageTotals = .zero, rows: [LLMUsagePurposeRow] = []) {
        self.totals = totals
        self.rows = rows
    }

    enum CodingKeys: String, CodingKey { case totals, rows }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totals = try c.decode(LLMUsageTotals.self, forKey: .totals)
        rows = try c.decodeIfPresent([LLMUsagePurposeRow].self, forKey: .rows) ?? []
    }
}

package struct LLMUsagePurposeRow: Decodable, Equatable, Sendable, Identifiable {
    /// "" for an untagged call; `process` then names who made it.
    package var purpose: String
    package var process: String
    package var models: [String]
    package var calls: Int64
    package var input: Int64
    package var cacheRead: Int64
    package var cacheWrite: Int64
    package var output: Int64
    package var costUSD: Double?
    package var costIsEstimate: Bool
    package var costIsLowerBound: Bool
    package var perCallTokens: Int64

    package init(
        purpose: String,
        process: String = "",
        models: [String] = [],
        calls: Int64,
        input: Int64 = 0,
        cacheRead: Int64 = 0,
        cacheWrite: Int64 = 0,
        output: Int64 = 0,
        costUSD: Double? = nil,
        costIsEstimate: Bool = false,
        costIsLowerBound: Bool = false,
        perCallTokens: Int64 = 0
    ) {
        self.purpose = purpose
        self.process = process
        self.models = models
        self.calls = calls
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
        self.costUSD = costUSD
        self.costIsEstimate = costIsEstimate
        self.costIsLowerBound = costIsLowerBound
        self.perCallTokens = perCallTokens
    }

    package var id: String { purpose + "\u{1F}" + process }
    package var isUntagged: Bool { purpose.isEmpty }
    package var tokens: Int64 { input + cacheRead + cacheWrite + output }

    /// The process's name in the table: the purpose's display name, or
    /// "Untagged (<process>)".
    package var displayName: String {
        guard isUntagged else { return LLMPurposeNames.display(purpose: purpose).name }
        return process.isEmpty ? "Untagged" : "Untagged (\(process))"
    }

    enum CodingKeys: String, CodingKey {
        case purpose, process, models, calls, input, output
        case cacheRead = "cache_read", cacheWrite = "cache_write", costUSD = "cost_usd"
        case costIsEstimate = "cost_is_estimate", costIsLowerBound = "cost_is_lower_bound"
        case perCallTokens = "per_call_tokens"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        purpose = try c.decode(String.self, forKey: .purpose)
        process = try c.decodeIfPresent(String.self, forKey: .process) ?? ""
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        calls = try c.decode(Int64.self, forKey: .calls)
        input = try c.decode(Int64.self, forKey: .input)
        cacheRead = try c.decode(Int64.self, forKey: .cacheRead)
        cacheWrite = try c.decode(Int64.self, forKey: .cacheWrite)
        output = try c.decode(Int64.self, forKey: .output)
        costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD)
        costIsEstimate = try c.decodeIfPresent(Bool.self, forKey: .costIsEstimate) ?? false
        costIsLowerBound = try c.decodeIfPresent(Bool.self, forKey: .costIsLowerBound) ?? false
        perCallTokens = try c.decodeIfPresent(Int64.self, forKey: .perCallTokens) ?? 0
    }
}

/// "Your automations": the owner's own automations, outside the Watchtower total.
package struct LLMUsageAutomations: Decodable, Equatable, Sendable {
    package var totals: LLMUsageTotals
    package var rows: [LLMUsageAutomationRow]

    package init(totals: LLMUsageTotals = .zero, rows: [LLMUsageAutomationRow] = []) {
        self.totals = totals
        self.rows = rows
    }

    enum CodingKeys: String, CodingKey { case totals, rows }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totals = try c.decode(LLMUsageTotals.self, forKey: .totals)
        rows = try c.decodeIfPresent([LLMUsageAutomationRow].self, forKey: .rows) ?? []
    }
}

package struct LLMUsageAutomationRow: Decodable, Equatable, Sendable, Identifiable {
    package var automationID: Int64
    package var name: String
    package var runs: Int64
    package var calls: Int64
    package var input: Int64
    package var output: Int64
    package var costUSD: Double?
    package var costIsEstimate: Bool
    /// Some call of the automation had no price: the cost is "at least".
    package var costIsLowerBound: Bool

    package var id: Int64 { automationID }

    package init(
        automationID: Int64,
        name: String,
        runs: Int64,
        calls: Int64,
        input: Int64 = 0,
        output: Int64 = 0,
        costUSD: Double? = nil,
        costIsEstimate: Bool = false,
        costIsLowerBound: Bool = false
    ) {
        self.automationID = automationID
        self.name = name
        self.runs = runs
        self.calls = calls
        self.input = input
        self.output = output
        self.costUSD = costUSD
        self.costIsEstimate = costIsEstimate
        self.costIsLowerBound = costIsLowerBound
    }
    package var tokens: Int64 { input + output }

    enum CodingKeys: String, CodingKey {
        case name, runs, calls, input, output
        case automationID = "automation_id", costUSD = "cost_usd", costIsEstimate = "cost_is_estimate"
        case costIsLowerBound = "cost_is_lower_bound"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        automationID = try c.decode(Int64.self, forKey: .automationID)
        name = try c.decode(String.self, forKey: .name)
        runs = try c.decode(Int64.self, forKey: .runs)
        calls = try c.decode(Int64.self, forKey: .calls)
        input = try c.decode(Int64.self, forKey: .input)
        output = try c.decode(Int64.self, forKey: .output)
        costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD)
        costIsEstimate = try c.decodeIfPresent(Bool.self, forKey: .costIsEstimate) ?? false
        costIsLowerBound = try c.decodeIfPresent(Bool.self, forKey: .costIsLowerBound) ?? false
    }
}

/// Workbenches: agent sessions (agent analytics, workbenches with it on)
/// plus Watchtower's helper calls made for workbench features.
package struct LLMUsageWorkbenches: Decodable, Equatable, Sendable {
    package var totals: LLMUsageTotals
    package var sessions: LLMUsageTotals
    package var helpers: LLMUsageTotals
    /// Workbenches with agent analytics off: their sessions are not counted.
    package var analyticsOff: [String]

    package init(
        totals: LLMUsageTotals = .zero,
        sessions: LLMUsageTotals = .zero,
        helpers: LLMUsageTotals = .zero,
        analyticsOff: [String] = []
    ) {
        self.totals = totals
        self.sessions = sessions
        self.helpers = helpers
        self.analyticsOff = analyticsOff
    }

    enum CodingKeys: String, CodingKey {
        case totals, sessions, helpers
        case analyticsOff = "analytics_off"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totals = try c.decode(LLMUsageTotals.self, forKey: .totals)
        sessions = try c.decode(LLMUsageTotals.self, forKey: .sessions)
        helpers = try c.decode(LLMUsageTotals.self, forKey: .helpers)
        analyticsOff = try c.decodeIfPresent([String].self, forKey: .analyticsOff) ?? []
    }
}

/// The tab's period picker; the raw value is the `--since` argument.
package enum LLMUsagePeriod: String, CaseIterable, Sendable {
    case today
    case sevenDays = "7d"
    case thirtyDays = "30d"

    package var title: String {
        switch self {
        case .today: "Today"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        }
    }

    /// Where the period starts, as `usage llm` counts it: local midnight for
    /// today, else that many days back from now.
    package func start(now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .today: calendar.startOfDay(for: now)
        case .sevenDays: now.addingTimeInterval(-7 * 86400)
        case .thirtyDays: now.addingTimeInterval(-30 * 86400)
        }
    }
}

/// Why `usage llm` could not be read: the error state's subtitle.
package enum LLMUsageLoadError: Equatable, Sendable {
    case cliMissing
    case timedOut
    case couldNotStart
    case failed(exitCode: Int32)
    case unreadable

    package init(_ error: Error) {
        switch error {
        case CLIRunnerError.binaryNotFound: self = .cliMissing
        // `ProcessCLIRunner`'s deadline is the only source of exit -1.
        case CLIRunnerError.nonZeroExit(code: -1, _): self = .timedOut
        case let CLIRunnerError.nonZeroExit(code, _): self = .failed(exitCode: code)
        case CLIRunnerError.launchFailed: self = .couldNotStart
        default: self = .unreadable
        }
    }

    package var subtitle: String {
        switch self {
        case .cliMissing: "The watchtower command is not installed."
        case .timedOut: "The command timed out."
        case .couldNotStart: "The command could not start."
        case let .failed(code): "The command failed (exit \(code))."
        case .unreadable: "The command's answer could not be read."
        }
    }
}

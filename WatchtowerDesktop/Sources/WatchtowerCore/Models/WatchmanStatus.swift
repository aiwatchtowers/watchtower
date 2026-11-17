import Foundation

/// Decoded `watchtower watchman status --json` (`cmd/watchman.go`, keys
/// pinned by `TestWatchmanStatus_JSONKeysPinned`; the Go test writes
/// `internal/watchman/testdata/status.json`, which `WatchmanStatusDecodingTests`
/// reads). Fields the CLI may print as `null` or leave out are optional.
package struct WatchmanStatus: Decodable, Equatable, Sendable {
    package let ok: Bool
    package let workbenches: [WatchmanWorkbenchStatus]

    enum CodingKeys: String, CodingKey { case ok, workbenches }

    package init(ok: Bool = true, workbenches: [WatchmanWorkbenchStatus]) {
        self.ok = ok
        self.workbenches = workbenches
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        // A nil Go slice marshals to null: an empty list, not a decode failure.
        workbenches = try container.decodeIfPresent([WatchmanWorkbenchStatus].self, forKey: .workbenches) ?? []
    }

    package func workbench(_ id: Int64) -> WatchmanWorkbenchStatus? {
        workbenches.first { $0.workbench == id }
    }
}

package struct WatchmanWorkbenchStatus: Decodable, Equatable, Sendable {
    package let workbench: Int64
    package let name: String
    /// RFC 3339; nil while Watchman is not on for the workbench.
    package let enabledAt: String?
    package let analyticsOn: Bool
    package let precedents: [String: Int]
    package let sources: [String: WatchmanSourceProgress]
    /// `"HH:MM-HH:MM"`; empty while not learned.
    package let sleepWindow: String?
    package let sleepWindowPinned: Bool
    /// The counts-only estimate of a workbench Watchman is not on for.
    package let estimate: WatchmanEstimate?
    /// The first learning pass of an enabled workbench.
    package let learning: WatchmanLearning?
    /// The newest backtest row, whatever its status.
    package let backtest: WatchmanBacktest?
    /// The newest finished backtest.
    package let lastDone: WatchmanBacktest?
    /// The workspace-wide Watchman lock is held (the same on every row).
    package let running: Bool

    enum CodingKeys: String, CodingKey {
        case workbench, name, precedents, sources, estimate, learning, backtest, running
        case enabledAt = "enabled_at", analyticsOn = "analytics_on"
        case sleepWindow = "sleep_window", sleepWindowPinned = "sleep_window_pinned"
        case lastDone = "last_done"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workbench = try container.decode(Int64.self, forKey: .workbench)
        name = try container.decode(String.self, forKey: .name)
        enabledAt = try container.decodeIfPresent(String.self, forKey: .enabledAt)
        analyticsOn = try container.decode(Bool.self, forKey: .analyticsOn)
        precedents = try container.decodeIfPresent([String: Int].self, forKey: .precedents) ?? [:]
        sources = try container.decodeIfPresent([String: WatchmanSourceProgress].self, forKey: .sources) ?? [:]
        sleepWindow = try container.decodeIfPresent(String.self, forKey: .sleepWindow)
        sleepWindowPinned = try container.decodeIfPresent(Bool.self, forKey: .sleepWindowPinned) ?? false
        estimate = try container.decodeIfPresent(WatchmanEstimate.self, forKey: .estimate)
        learning = try container.decodeIfPresent(WatchmanLearning.self, forKey: .learning)
        backtest = try container.decodeIfPresent(WatchmanBacktest.self, forKey: .backtest)
        lastDone = try container.decodeIfPresent(WatchmanBacktest.self, forKey: .lastDone)
        running = try container.decode(Bool.self, forKey: .running)
    }

    package var isEnabled: Bool { !(enabledAt ?? "").isEmpty }
    package var isLearned: Bool { isEnabled && (learning?.done ?? false) }
}

package struct WatchmanSourceProgress: Decodable, Equatable, Sendable {
    package let written: Int
    package let done: Bool
}

package struct WatchmanEstimate: Decodable, Equatable, Sendable {
    package let decisions: Int
    package let needLabels: Int
    package let tokens: Int

    enum CodingKeys: String, CodingKey {
        case decisions, tokens
        case needLabels = "need_labels"
    }
}

package struct WatchmanLearning: Decodable, Equatable, Sendable {
    package let written: Int
    package let estimated: Int
    package let done: Bool
}

package struct WatchmanBacktest: Decodable, Equatable, Sendable {
    package let id: Int64
    /// `running`, `done`, `failed` or `interrupted` (a running row whose
    /// process died; shown like `failed`).
    package let status: String
    package let startedAt: String?
    package let finishedAt: String?
    package let error: String?
    /// `go` or `stop` once finished.
    package let verdict: String?
    package let costUSD: Double
    /// `"<category>, <i> of <n> · <k> of 8 categories done"` while running.
    package let progress: String?
    package let categories: [WatchmanBacktestCategory]

    enum CodingKeys: String, CodingKey {
        case id, status, error, verdict, progress, categories
        case startedAt = "started_at", finishedAt = "finished_at", costUSD = "cost_usd"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        status = try container.decode(String.self, forKey: .status)
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(String.self, forKey: .finishedAt)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        verdict = try container.decodeIfPresent(String.self, forKey: .verdict)
        costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        progress = try container.decodeIfPresent(String.self, forKey: .progress)
        categories = try container.decodeIfPresent([WatchmanBacktestCategory].self, forKey: .categories) ?? []
    }

    package var isFailed: Bool { status == "failed" || status == "interrupted" }
}

/// One category's backtest row: `total` scored decisions the judge graded
/// same (`agree`), `acceptable` or `bad`; strong = at most 5 % bad and none
/// bad while sure (ask #1423).
package struct WatchmanBacktestCategory: Decodable, Equatable, Sendable {
    package let category: String
    package let total: Int
    package let agree: Int
    package let acceptable: Int
    package let bad: Int
    /// Bad decisions taken while the twin's confidence was high.
    package let wrongHigh: Int
    package let costUSD: Double
    /// The share of the hidden decisions that always giving the owner's most
    /// common choice would get right (informational).
    package let baseline: Double
    /// The share of the decisions where the owner picked the option the agent
    /// recommended (informational).
    package let recBaseline: Double
    /// `strong`, `weak` or `not_measured`.
    package let status: String

    enum CodingKeys: String, CodingKey {
        case category, total, agree, acceptable, bad, status, baseline
        case wrongHigh = "wrong_high", costUSD = "cost_usd", recBaseline = "rec_baseline"
    }

    package init(
        category: String,
        total: Int,
        agree: Int,
        acceptable: Int = 0,
        bad: Int = 0,
        wrongHigh: Int,
        costUSD: Double,
        baseline: Double = 0,
        recBaseline: Double = 0,
        status: String
    ) {
        self.category = category
        self.total = total
        self.agree = agree
        self.acceptable = acceptable
        self.bad = bad
        self.wrongHigh = wrongHigh
        self.costUSD = costUSD
        self.baseline = baseline
        self.recBaseline = recBaseline
        self.status = status
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        category = try container.decode(String.self, forKey: .category)
        total = try container.decode(Int.self, forKey: .total)
        agree = try container.decode(Int.self, forKey: .agree)
        acceptable = try container.decodeIfPresent(Int.self, forKey: .acceptable) ?? 0
        bad = try container.decodeIfPresent(Int.self, forKey: .bad) ?? 0
        wrongHigh = try container.decode(Int.self, forKey: .wrongHigh)
        costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        baseline = try container.decodeIfPresent(Double.self, forKey: .baseline) ?? 0
        recBaseline = try container.decodeIfPresent(Double.self, forKey: .recBaseline) ?? 0
        status = try container.decode(String.self, forKey: .status)
    }
}

// MARK: - Screen state

/// Where one workbench stands in Settings → Watchman.
package enum WatchmanWorkbenchPhase: Equatable, Sendable {
    /// Watchman is not on: the estimate and Start Learning.
    case notLearned
    /// The first learning pass runs (here or in the daemon).
    case learning
    case neverRun
    /// A backtest runs; the status's progress line.
    case running(progress: String)
    case failed(message: String)
    case results

    /// `learningHere` / `backtestHere`: this app started the CLI call and it
    /// has not returned yet (the status may not show it so far).
    package static func of(
        _ row: WatchmanWorkbenchStatus, learningHere: Bool = false, backtestHere: Bool = false
    ) -> Self {
        // `running` is the workspace-wide lock, the same on every row: only
        // the row whose latest backtest is `running` (or that this app just
        // started) runs.
        if backtestHere || row.backtest?.status == "running" {
            let progress = row.backtest?.status == "running" ? row.backtest?.progress ?? "" : ""
            return .running(progress: progress)
        }
        if learningHere || (row.isEnabled && !row.isLearned) { return .learning }
        if !row.isEnabled { return .notLearned }
        if let backtest = row.backtest, backtest.isFailed {
            return .failed(message: backtest.error ?? "")
        }
        return row.lastDone == nil ? .neverRun : .results
    }
}

/// Settings → Watchman as a whole: the phase of its focus workbench — the
/// first one Watchman is on for (or learning here), else nothing is learned.
package enum WatchmanSettingsState: Equatable, Sendable {
    case loading
    case notLearned(WatchmanStatus)
    case learning(WatchmanStatus, workbench: Int64)
    case neverRun(WatchmanStatus)
    case running(WatchmanStatus, progress: String)
    case failed(WatchmanStatus, message: String)
    case results(WatchmanStatus)
    case readFailed(String)

    package static func of(
        _ status: WatchmanStatus, learningHere: Set<Int64> = [], backtestHere: Set<Int64> = []
    ) -> Self {
        let focus = status.workbenches.first {
            $0.isEnabled || learningHere.contains($0.workbench) || backtestHere.contains($0.workbench)
        }
        guard let focus else { return .notLearned(status) }
        let phase = WatchmanWorkbenchPhase.of(
            focus, learningHere: learningHere.contains(focus.workbench),
            backtestHere: backtestHere.contains(focus.workbench)
        )
        switch phase {
        case .notLearned: return .notLearned(status)
        case .learning: return .learning(status, workbench: focus.workbench)
        case .neverRun: return .neverRun(status)
        case let .running(progress): return .running(status, progress: progress)
        case let .failed(message): return .failed(status, message: message)
        case .results: return .results(status)
        }
    }

    /// The report this state shows; nil while loading or after a failed read.
    package var status: WatchmanStatus? {
        switch self {
        case .loading, .readFailed: nil
        case let .notLearned(status), let .learning(status, _), let .neverRun(status),
             let .running(status, _), let .failed(status, _), let .results(status): status
        }
    }
}

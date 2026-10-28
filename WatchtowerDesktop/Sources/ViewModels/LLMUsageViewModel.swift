import Foundation
import Observation
import WatchtowerCore

/// Reads `watchtower usage llm --since <period> --json` for the Usage →
/// Watchtower tab (and Home's AI spend, with period `today`). The caller owns
/// the period (the tab keeps it in `@AppStorage`) and the refresh cadence.
/// A failed refresh keeps the last report; a new period drops it.
@MainActor
@Observable
final class LLMUsageViewModel {
    /// The command's deadline: a hung read must not hold the tab.
    static let timeout: TimeInterval = 10

    var period: LLMUsagePeriod {
        didSet {
            guard period != oldValue else { return }
            report = nil
            error = nil
            lastUpdated = nil
        }
    }

    private(set) var report: LLMUsageReport?
    /// The latest read's failure; nil after a good read.
    private(set) var error: LLMUsageLoadError?
    /// When `report` was read.
    private(set) var lastUpdated: Date?

    @ObservationIgnored private let makeRunner: () -> (any CLIRunnerProtocol)?
    @ObservationIgnored private let now: () -> Date

    /// `makeRunner` runs at every read, so a CLI installed after launch is found.
    init(
        period: LLMUsagePeriod,
        makeRunner: @escaping () -> (any CLIRunnerProtocol)? = { ProcessCLIRunner.makeDefault() },
        now: @escaping () -> Date = Date.init
    ) {
        self.period = period
        self.makeRunner = makeRunner
        self.now = now
    }

    static func args(for period: LLMUsagePeriod) -> [String] {
        ["usage", "llm", "--since", period.rawValue, "--json"]
    }

    func screen(now: Date) -> LLMUsageScreen {
        LLMUsagePresentation.screen(report: report, error: error, lastUpdated: lastUpdated, period: period, now: now)
    }

    /// One read. An answer for a period the picker has since left is dropped,
    /// and a cancelled read (the tab went away) changes nothing.
    func load() async {
        let asked = period
        guard let runner = makeRunner() else {
            error = .cliMissing
            return
        }
        do {
            let data = try await runner.run(args: Self.args(for: asked), timeout: Self.timeout)
            let decoded = try JSONDecoder().decode(LLMUsageReport.self, from: data)
            guard asked == period, !Task.isCancelled else { return }
            report = decoded
            error = nil
            lastUpdated = now()
        } catch {
            guard asked == period, !Task.isCancelled else { return }
            self.error = LLMUsageLoadError(error)
        }
    }

    /// Reads now and then every `interval` seconds until the calling task is
    /// cancelled (the view's `.task` ends when the tab disappears).
    func refreshLoop(every interval: TimeInterval) async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(interval))
        }
    }
}

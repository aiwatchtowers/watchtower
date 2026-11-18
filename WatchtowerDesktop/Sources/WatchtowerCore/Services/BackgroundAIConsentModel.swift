import Foundation
import Observation

/// The consent screen's model (#1886, spec §5), shared by onboarding's last
/// step and the sheet: the copy for the configured agent and reserve, the
/// "what runs" rows from `sync.poll_interval` and `sync.backfill_days`, and
/// the answer, written only through `watchtower ai background allow|pause`
/// (the one writer of `ai.background_runs`).
@MainActor
@Observable
package final class BackgroundAIConsentModel {
    /// `config.DefaultBackfillDays` in Go.
    package static let defaultBackfillDays = 30

    package let agent: BackgroundAIConsentCopy.Agent
    package let reserve: BackgroundAIConsentCopy.Agent?
    package let whatRuns: [String]
    /// The answer is being written: both buttons are off.
    package private(set) var isSaving = false
    /// The last write failed (`BackgroundAIConsentCopy.saveFailed`); cleared
    /// by the next answer.
    package private(set) var errorLine: String?

    @ObservationIgnored private let runner: any CLIRunnerProtocol
    @ObservationIgnored private let configPath: String

    package init(
        runner: any CLIRunnerProtocol,
        configPath: String,
        agent: BackgroundAIConsentCopy.Agent,
        reserve: BackgroundAIConsentCopy.Agent?,
        pollMinutes: Int,
        backfillDays: Int
    ) {
        self.runner = runner
        self.configPath = configPath
        self.agent = agent
        self.reserve = reserve
        whatRuns = BackgroundAIConsentCopy.whatRuns(pollMinutes: pollMinutes, backfillDays: backfillDays)
    }

    /// Whose plan the runs use, then the reserve line while the automatic
    /// reserve is on.
    package var planLines: [String] {
        [BackgroundAIConsentCopy.plan(agent)] + (reserve.map { [BackgroundAIConsentCopy.reserve(from: agent, to: $0)] } ?? [])
    }

    /// `ai background allow --yes`; true once it is saved.
    package func allow() async -> Bool {
        await answer(["allow", "--yes"])
    }

    /// `ai background pause`; true once it is saved.
    package func notNow() async -> Bool {
        await answer(["pause"])
    }

    private func answer(_ verb: [String]) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        errorLine = nil
        defer { isSaving = false }
        do {
            _ = try await runner.run(args: ["--config", configPath, "ai", "background"] + verb)
            return true
        } catch {
            errorLine = BackgroundAIConsentCopy.saveFailed(Self.reason(error))
            return false
        }
    }

    /// The CLI's own refusal (stderr's last line without cobra's "Error: "
    /// and a closing period, which the sentence adds), else the error's.
    private static func reason(_ error: Error) -> String {
        guard case let CLIRunnerError.nonZeroExit(code, stderr) = error else { return error.localizedDescription }
        var text = InboxFoldersCLI.lastLine(stderr)
        if text.hasPrefix("Error: ") { text.removeFirst("Error: ".count) }
        while text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? "watchtower exited with code \(code)" : text
    }
}

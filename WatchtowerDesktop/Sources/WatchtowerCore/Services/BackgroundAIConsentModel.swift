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
    /// The host's follow-up to a saved answer is running (onboarding's
    /// completion sequence): the buttons stay off.
    package private(set) var isFinishing = false
    /// The answer is saved but the host's follow-up failed: only that
    /// follow-up is offered again, the answer is not re-written.
    package private(set) var needsFinishRetry = false
    /// The last write failed (`BackgroundAIConsentCopy.saveFailed`, or
    /// `pauseFailed` for Settings' `pause()`); cleared
    /// by the next answer.
    package private(set) var errorLine: String?

    /// Saving or finishing: nothing on the screen can be pressed.
    package var isBusy: Bool { isSaving || isFinishing }

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
        await write(["allow", "--yes"])
    }

    /// `ai background pause`; true once it is saved.
    package func notNow() async -> Bool {
        await write(["pause"])
    }

    /// Settings' switch turned off: `ai background pause`, whose failure says
    /// background AI is still on. True once it is saved.
    package func pause() async -> Bool {
        await write(["pause"], failure: BackgroundAIConsentCopy.pauseFailed)
    }

    package enum Choice: Sendable {
        case allow, notNow
    }

    /// Writes `choice`, then runs the host's follow-up (`finish`, true on
    /// success) with the buttons still off. A failed follow-up leaves
    /// `needsFinishRetry`: `retryFinish` runs only the follow-up again.
    package func answer(_ choice: Choice, finish: @MainActor () async -> Bool) async {
        guard !isBusy, !needsFinishRetry else { return }
        let saved = choice == .allow ? await allow() : await notNow()
        guard saved else { return }
        await runFinish(finish)
    }

    package func retryFinish(_ finish: @MainActor () async -> Bool) async {
        guard !isBusy, needsFinishRetry else { return }
        await runFinish(finish)
    }

    private func runFinish(_ finish: @MainActor () async -> Bool) async {
        isFinishing = true
        defer { isFinishing = false }
        needsFinishRetry = !(await finish())
    }

    private func write(
        _ verb: [String],
        failure: (String) -> String = BackgroundAIConsentCopy.saveFailed
    ) async -> Bool {
        guard !isBusy else { return false }
        isSaving = true
        errorLine = nil
        defer { isSaving = false }
        do {
            _ = try await runner.run(args: ["--config", configPath, "ai", "background"] + verb)
            return true
        } catch {
            errorLine = failure(Self.reason(error))
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

/// What the consent screen discloses, read from the persisted config.yaml
/// when the screen opens: never from Settings' unsaved edits, and after a
/// provider switch in onboarding's Goals step.
package struct BackgroundAIConsentSetup: Equatable, Sendable {
    package let agent: BackgroundAIConsentCopy.Agent
    /// Only while the automatic reserve (`ai.fallback.enabled`) is on.
    package let reserve: BackgroundAIConsentCopy.Agent?
    package let pollMinutes: Int
    package let backfillDays: Int

    /// `yaml` is the parsed file (empty when absent or unreadable).
    /// `displayName` and `reservePeer` come from the provider catalog.
    package static func read(
        _ yaml: [String: Any],
        displayName: (String) -> String,
        reservePeer: (String) -> String?
    ) -> Self {
        let ai = yaml["ai"] as? [String: Any] ?? [:]
        let sync = yaml["sync"] as? [String: Any] ?? [:]
        let fallback = ai["fallback"] as? [String: Any] ?? [:]
        let provider = (ai["provider"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "claude"
        func agent(_ id: String) -> BackgroundAIConsentCopy.Agent {
            BackgroundAIConsentCopy.Agent(provider: id, displayName: displayName(id))
        }
        let reserveID = (fallback["enabled"] as? Bool ?? false)
            ? (fallback["provider"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? reservePeer(provider)
            : nil
        let poll = sync["poll_interval"].map { "\($0)" }
        return Self(
            agent: agent(provider),
            reserve: reserveID.map { agent($0) },
            pollMinutes: FeatureReadiness.parsePollInterval(poll),
            backfillDays: sync["backfill_days"] as? Int ?? BackgroundAIConsentModel.defaultBackfillDays
        )
    }
}

extension BackgroundAIConsentModel {
    package convenience init(runner: any CLIRunnerProtocol, configPath: String, setup: BackgroundAIConsentSetup) {
        self.init(
            runner: runner, configPath: configPath, agent: setup.agent, reserve: setup.reserve,
            pollMinutes: setup.pollMinutes, backfillDays: setup.backfillDays
        )
    }
}

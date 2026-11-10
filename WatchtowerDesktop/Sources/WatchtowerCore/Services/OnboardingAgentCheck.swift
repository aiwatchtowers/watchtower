import Foundation

/// What one `ai test --json` answered, as far as the Goals step needs it.
package struct OnboardingAgentTestResult: Equatable, Sendable {
    package var ok: Bool
    package var errorCode: String?
    package var error: String?

    package init(ok: Bool, errorCode: String? = nil, error: String? = nil) {
        self.ok = ok
        self.errorCode = errorCode
        self.error = error
    }
}

/// The side effects of the per-agent check, injected so the check itself is
/// pure ordering and mapping (#1521).
package struct OnboardingAgentProbes: Sendable {
    /// `ai.provider`; nil or blank = unset.
    package var configuredProvider: String?
    /// The managed policy's `AllowedAIProviders`.
    package var allowed: @Sendable (OnboardingAgentChoice.Agent) -> Bool
    /// Go's own binary lookup (`ai which`); nil = not found.
    package var locate: @Sendable (OnboardingAgentChoice.Agent) async -> String?
    /// The path with symlinks followed, for `InstallKind`.
    package var resolve: @Sendable (String) -> String
    /// The login help text of an executable; nil = the probe timed out.
    package var help: @Sendable (OnboardingAgentChoice.Agent, String) async -> String?
    /// `ai test --json`: (provider or nil = the configured one, executable for `--cli-path`).
    package var test: @Sendable (String?, String?) async -> OnboardingAgentTestResult
    package var home: String

    package init(
        configuredProvider: String?,
        allowed: @escaping @Sendable (OnboardingAgentChoice.Agent) -> Bool,
        locate: @escaping @Sendable (OnboardingAgentChoice.Agent) async -> String?,
        resolve: @escaping @Sendable (String) -> String,
        help: @escaping @Sendable (OnboardingAgentChoice.Agent, String) async -> String?,
        test: @escaping @Sendable (String?, String?) async -> OnboardingAgentTestResult,
        home: String
    ) {
        self.configuredProvider = configuredProvider
        self.allowed = allowed
        self.locate = locate
        self.resolve = resolve
        self.help = help
        self.test = test
        self.home = home
    }
}

package struct OnboardingAgentCheckResult: Equatable, Sendable {
    package var statuses: [OnboardingAgentChoice.Agent: OnboardingAgentChoice.Status] = [:]
    package var installs: [OnboardingAgentChoice.Agent: OnboardingAgentChoice.Install] = [:]
    package var outdated: Set<OnboardingAgentChoice.Agent> = []
    /// The display name of a working provider other than claude / codex.
    package var otherProvider: String?
    package var otherProviderFailure: String?

    package init(
        statuses: [OnboardingAgentChoice.Agent: OnboardingAgentChoice.Status] = [:],
        installs: [OnboardingAgentChoice.Agent: OnboardingAgentChoice.Install] = [:],
        outdated: Set<OnboardingAgentChoice.Agent> = [],
        otherProvider: String? = nil,
        otherProviderFailure: String? = nil
    ) {
        self.statuses = statuses
        self.installs = installs
        self.outdated = outdated
        self.otherProvider = otherProvider
        self.otherProviderFailure = otherProviderFailure
    }
}

package enum OnboardingAgentCheck {
    private typealias Agent = OnboardingAgentChoice.Agent

    private struct AgentOutcome: Sendable {
        var agent: Agent
        var status: OnboardingAgentChoice.Status
        var install: OnboardingAgentChoice.Install?
        var outdated: Bool
    }

    /// A missing or forbidden agent costs no request; installed ones are
    /// tested in parallel, each through the executable Go located.
    package static func run(_ probes: OnboardingAgentProbes) async -> OnboardingAgentCheckResult {
        var result = OnboardingAgentCheckResult()
        let configured = probes.configuredProvider?.trimmingCharacters(in: .whitespaces) ?? ""
        if !configured.isEmpty, Agent(rawValue: configured) == nil {
            let answer = await probes.test(nil, nil)
            result.otherProvider = OnboardingAgentChoice.providerName(configured)
            if !answer.ok {
                result.otherProviderFailure = OnboardingAgentChoice.otherFailureLine(code: answer.errorCode, error: answer.error)
            }
            if answer.ok { return result }
        }
        let outcomes = await withTaskGroup(of: AgentOutcome.self) { group in
            for agent in Agent.allCases {
                group.addTask { await check(agent, probes) }
            }
            var all: [AgentOutcome] = []
            for await outcome in group { all.append(outcome) }
            return all
        }
        for outcome in outcomes {
            result.statuses[outcome.agent] = outcome.status
            result.installs[outcome.agent] = outcome.install
            if outcome.outdated { result.outdated.insert(outcome.agent) }
        }
        return result
    }

    private static func check(_ agent: Agent, _ probes: OnboardingAgentProbes) async -> AgentOutcome {
        guard probes.allowed(agent) else {
            return AgentOutcome(agent: agent, status: .forbidden, install: nil, outdated: false)
        }
        guard let executable = await probes.locate(agent) else {
            return AgentOutcome(agent: agent, status: .notInstalled, install: nil, outdated: false)
        }
        let resolved = probes.resolve(executable)
        let install = OnboardingAgentChoice.Install(
            path: resolved,
            kind: OnboardingAgentChoice.InstallKind.of(agent, resolvedPath: resolved, home: probes.home),
            executable: executable
        )
        let answer = await probes.test(agent.rawValue, executable)
        let status: OnboardingAgentChoice.Status
        if answer.ok {
            status = .ready
        } else {
            switch answer.errorCode {
            case "auth": status = .signedOut
            case "policy": status = .forbidden
            default:
                status = .failed(OnboardingAgentChoice.failureMessage(agent, code: answer.errorCode, error: answer.error))
            }
        }
        var outdated = false
        if status == .signedOut {
            // A timed-out probe counts as outdated: never straight to a login that can't work.
            let text = await probes.help(agent, executable)
            outdated = text.map { !agent.loginSupported(help: $0) } ?? true
        }
        return AgentOutcome(agent: agent, status: status, install: install, outdated: outdated)
    }
}

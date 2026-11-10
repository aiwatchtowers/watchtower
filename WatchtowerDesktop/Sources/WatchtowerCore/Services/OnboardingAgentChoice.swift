import Foundation

/// The Goals step's AI agent section (#1521): which CLI Watchtower runs on,
/// picked by the owner. Pure state + every line of copy the section shows;
/// the view only lays it out. Spec:
/// `docs/superpowers/specs/2026-11-10-onboarding-agent-choice-design.md`.
package struct OnboardingAgentChoice: Equatable, Sendable {
    package enum Agent: String, CaseIterable, Sendable {
        case claude, codex

        package var name: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex CLI"
            }
        }

        package var installCommand: String {
            switch self {
            case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
            case .codex: "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
            }
        }

        package var signInCommand: String {
            switch self {
            case .claude: "claude"
            case .codex: "codex login"
            }
        }

        /// The config key a manually picked executable is saved under.
        package var pathKey: String {
            switch self {
            case .claude: "claude_path"
            case .codex: "codex_path"
            }
        }
    }

    package enum Status: Equatable, Sendable {
        case checking
        /// `ai test --provider <agent>` answered.
        case ready
        /// No executable at the configured path or on PATH. Known without a request.
        case notInstalled
        /// The test failed with `error_code: auth`.
        case signedOut
        /// Any other failed test; the CLI's sanitized message.
        case failed(String)
        /// `AllowedAIProviders` leaves this agent out.
        case forbidden
    }

    /// The status line's colour, mapped to `Tone` by the view.
    package enum Tone: Equatable, Sendable { case success, warning, error, neutral }

    package struct Tile: Equatable, Sendable {
        package var agent: Agent
        package var title: String
        package var status: String
        package var tone: Tone
        package var busy: Bool
        package var selected: Bool
        package var enabled: Bool
    }

    package struct Step: Equatable, Sendable {
        package var label: String
        package var command: String?
    }

    /// The panel under the tiles while the picked agent is not ready.
    package struct Setup: Equatable, Sendable {
        package var agent: Agent
        package var title: String
        package var steps: [Step]
        /// A CLI's message, shown under the steps.
        package var detail: String?
        package var showsManualPath: Bool
        package static let checkAgain = "Check again"
        package static let manualPath = "Choose the executable…"
        package static let autoCheck = "Watchtower checks again when you come back to this window."
    }

    package var statuses: [Agent: Status]
    package private(set) var selected: Agent?
    /// The owner tapped a tile: later checks never move the selection.
    package private(set) var picked = false
    /// The config's `ai.provider` when it is neither claude nor codex (an
    /// owner who set up Ollama in Settings): no tiles, one line.
    package var otherProvider: String?

    package init(
        statuses: [Agent: Status] = [.claude: .checking, .codex: .checking],
        otherProvider: String? = nil
    ) {
        self.statuses = statuses
        self.otherProvider = otherProvider
    }

    package func status(_ agent: Agent) -> Status { statuses[agent] ?? .checking }

    // MARK: Selection

    /// Picks the agent a fresh check lands on, unless the owner already
    /// picked one: the configured agent, else the first ready, else the
    /// first installed, else the first one the policy allows.
    package mutating func applyDefault(configured: String?) {
        guard !picked else { return }
        let allowed = Agent.allCases.filter { status($0) != .forbidden }
        if let configured, let agent = Agent(rawValue: configured), allowed.contains(agent) {
            selected = agent
            return
        }
        selected = allowed.first { status($0) == .ready }
            ?? allowed.first { status($0) != .notInstalled && status($0) != .checking }
            ?? allowed.first
    }

    package mutating func pick(_ agent: Agent) {
        guard status(agent) != .forbidden else { return }
        selected = agent
        picked = true
    }

    package var canContinue: Bool {
        if otherProvider != nil { return true }
        guard let selected else { return false }
        return status(selected) == .ready
    }

    package var isChecking: Bool {
        Agent.allCases.contains { status($0) == .checking }
    }

    /// Neither CLI is on this Mac (the policy may leave one out).
    package var noneInstalled: Bool {
        Agent.allCases.allSatisfy { status($0) == .notInstalled || status($0) == .forbidden }
            && Agent.allCases.contains { status($0) == .notInstalled }
    }

    // MARK: Copy

    package static let title = "AI agent"

    package var caption: String {
        if let otherProvider {
            return "Watchtower runs on \(otherProvider), set in Settings → AI."
        }
        if noneInstalled {
            return "Watchtower needs Claude Code or Codex CLI on this Mac. Pick one, install it and sign in — it takes a couple of minutes."
        }
        return "Chat, briefings and Workbench run on it. You can change it later in Settings → AI."
    }

    package func tile(_ agent: Agent) -> Tile {
        let state = status(agent)
        let (text, tone): (String, Tone) = switch state {
        case .checking: ("Checking…", .neutral)
        case .ready: ("Ready · signed in", .success)
        case .notInstalled: ("Not installed", .neutral)
        case .signedOut: ("Installed · not signed in", .warning)
        case .failed: ("Check failed", .error)
        case .forbidden: ("Turned off by your organization", .neutral)
        }
        return Tile(
            agent: agent,
            title: agent.name,
            status: text,
            tone: tone,
            busy: state == .checking,
            selected: selected == agent,
            enabled: state != .forbidden
        )
    }

    package var setup: Setup? {
        guard otherProvider == nil, let agent = selected else { return nil }
        switch status(agent) {
        case .checking, .ready, .forbidden:
            return nil
        case .notInstalled:
            return Setup(
                agent: agent,
                title: "Install \(agent.name)",
                steps: [
                    Step(label: "Install it in Terminal:", command: agent.installCommand),
                    Step(label: "Sign in:", command: agent.signInCommand)
                ],
                detail: nil,
                showsManualPath: true
            )
        case .signedOut:
            return Setup(
                agent: agent,
                title: "Sign in to \(agent.name)",
                steps: [Step(label: "Run in Terminal and follow the prompts:", command: agent.signInCommand)],
                detail: nil,
                showsManualPath: false
            )
        case .failed(let message):
            return Setup(
                agent: agent,
                title: "\(agent.name) didn’t answer",
                steps: [],
                detail: message,
                showsManualPath: true
            )
        }
    }

    /// The footer line beside a disabled Continue.
    package var continueHint: String? {
        guard !canContinue else { return nil }
        if isChecking { return nil }
        guard let selected else { return "Continue unlocks once an AI agent is ready" }
        return "Continue unlocks once \(selected.name) is ready"
    }

    /// The Development goal's pitch names the agent that will work the board.
    package var developmentPitch: String {
        let name = (otherProvider == nil ? selected?.name : nil) ?? "Your AI agent"
        return "\(name) works your folder’s board. No connections needed"
    }

    /// The `ai.provider` to write on Continue, nil when nothing changes.
    package func providerToSave(configured: String?) -> String? {
        guard otherProvider == nil, let selected, canContinue else { return nil }
        // An unset provider is written too: the choice is explicit from now on.
        let current = configured?.trimmingCharacters(in: .whitespaces) ?? ""
        return current == selected.rawValue ? nil : selected.rawValue
    }

    package static let saveFailure = "Couldn’t save the AI agent."
}

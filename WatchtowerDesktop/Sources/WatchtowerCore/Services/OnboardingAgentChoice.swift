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
            case .claude: "claude auth login"
            case .codex: "codex login"
            }
        }

        /// The vendor's install page: Homebrew, npm and the rest, for a Mac
        /// where piping a script into the shell is not allowed.
        package var installDocsURL: String {
            switch self {
            case .claude: "https://code.claude.com/docs/en/setup"
            case .codex: "https://github.com/openai/codex"
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
        /// Any other failed test; the line `failureMessage` built.
        case failed(String)
        /// `AllowedAIProviders` leaves this agent out (the Swift policy
        /// read, or the test's `error_code: policy`).
        case forbidden
    }

    /// The embedded sign-in terminal of the picked agent (owner, ask #1157:
    /// "if not signed in, open the console right there").
    package enum SignIn: Equatable, Sendable {
        case idle
        /// `<agent> auth login` / `codex login` runs in the panel.
        case running
        /// It ended without signing in (non-zero exit, or stopped).
        case ended(Int32?)
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
        package var docsURL: String?
        /// The panel hosts the sign-in terminal (signed out).
        package var runsSignIn: Bool
        /// The line above that terminal; `signInNoteWarns` when it ended badly.
        package var signInNote: String?
        package var signInNoteWarns = false
        package static let docsLink = "Other ways to install"
        package static let checkAgain = "Check again"
        package static let manualPath = "Choose the executable…"
        package static let autoCheck = "Watchtower checks again when you come back to this window."
    }

    package var statuses: [Agent: Status]
    package private(set) var signIn: SignIn = .idle
    /// Agents whose sign-in already started once: the terminal opens by
    /// itself only the first time, never again after a Stop.
    package private(set) var signInOpened: Set<Agent> = []
    package private(set) var selected: Agent?
    /// The owner tapped a tile: later checks never move the selection.
    package private(set) var picked = false
    /// The config's `ai.provider` when it is neither claude nor codex (an
    /// owner who set up Ollama in Settings): no tiles, one line.
    package var otherProvider: String?
    /// That provider's test failed: the tiles come back so the owner can
    /// pick Claude Code or Codex instead.
    package var otherProviderFailure: String?

    package init(
        statuses: [Agent: Status] = [.claude: .checking, .codex: .checking],
        otherProvider: String? = nil,
        otherProviderFailure: String? = nil
    ) {
        self.otherProviderFailure = otherProviderFailure
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
        if selected != agent { signIn = .idle }
        selected = agent
        picked = true
    }

    // MARK: Sign-in terminal

    /// The agent whose sign-in should open now by itself: the picked one,
    /// signed out, not opened before.
    package var signInToOpen: Agent? {
        guard let agent = selected, status(agent) == .signedOut, signIn == .idle,
              !signInOpened.contains(agent) else { return nil }
        return agent
    }

    package mutating func signInStarted() {
        guard let selected else { return }
        signIn = .running
        signInOpened.insert(selected)
    }

    /// The process ended; `0` means signed in — the caller checks again.
    package mutating func signInEnded(exitCode: Int32) {
        signIn = exitCode == 0 ? .idle : .ended(exitCode)
    }

    package mutating func signInStopped() { signIn = .ended(nil) }

    /// The tiles show unless a working provider was set elsewhere.
    package var showsTiles: Bool { otherProvider == nil || otherProviderFailure != nil }

    package var canContinue: Bool {
        if otherProvider != nil, otherProviderFailure == nil { return true }
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
            if let otherProviderFailure {
                return "\(otherProvider), set in Settings → AI, didn’t answer: \(otherProviderFailure) "
                    + "Pick Claude Code or Codex CLI instead, or fix it in Settings and check again."
            }
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
        guard showsTiles, let agent = selected else { return nil }
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
                showsManualPath: true,
                docsURL: agent.installDocsURL,
                runsSignIn: false
            )
        case .signedOut:
            return Setup(
                agent: agent,
                title: "Sign in to \(agent.name)",
                steps: [Step(label: "Or run it in your own Terminal:", command: agent.signInCommand)],
                detail: nil,
                showsManualPath: false,
                docsURL: nil,
                runsSignIn: true,
                signInNote: signInLine,
                signInNoteWarns: signIn != .idle && signIn != .running
            )
        case .failed(let message):
            return Setup(
                agent: agent,
                title: "\(agent.name) didn’t answer",
                steps: [],
                detail: message,
                showsManualPath: true,
                docsURL: nil,
                runsSignIn: false
            )
        }
    }

    /// The line above the sign-in terminal.
    private var signInLine: String {
        switch signIn {
        case .idle, .running:
            return "Your browser opens to sign in. When it’s done, this closes and Watchtower checks again."
        case .ended(let code?):
            return "Sign-in stopped before it finished (exit code \(code))."
        case .ended(nil):
            return "Sign-in stopped before it finished."
        }
    }

    package static let signInAgain = "Sign in again"
    package static let stopSignIn = "Stop"

    /// The footer line beside a disabled Continue.
    package var continueHint: String? {
        guard !canContinue else { return nil }
        if isChecking { return nil }
        guard let selected else { return "Continue unlocks once an AI agent is ready" }
        return "Continue unlocks once \(selected.name) is ready"
    }

    /// The Development goal's pitch names the agent that will work the board.
    package var developmentPitch: String {
        let name = (showsTiles ? selected?.name : nil) ?? "Your AI agent"
        return "\(name) works your folder’s board. No connections needed"
    }

    /// The `ai.provider` to write on Continue, nil when nothing changes.
    package func providerToSave(configured: String?) -> String? {
        guard showsTiles, let selected, canContinue else { return nil }
        // An unset provider is written too: the choice is explicit from now on.
        let current = configured?.trimmingCharacters(in: .whitespaces) ?? ""
        return current == selected.rawValue ? nil : selected.rawValue
    }

    /// The Failed line from `ai test --json`'s `error_code`: the CLI's own
    /// message is a bare category, so the code picks the words.
    package static func failureMessage(_ agent: Agent, code: String?, error: String?) -> String {
        switch code {
        case "transport", "timeout":
            return "Couldn’t reach \(agent.name)’s service. Check the network or VPN, then check again."
        case "invalid_output":
            if let error, !error.isEmpty { return error }
            return "\(agent.name) answered but ignored Watchtower’s instructions. Update it and check again."
        default:
            let tail = error.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
            return "\(agent.name) didn’t answer\(tail). Run it once in Terminal to see what it says, then check again."
        }
    }

    package static let saveFailure = "Couldn’t save the AI agent."
}

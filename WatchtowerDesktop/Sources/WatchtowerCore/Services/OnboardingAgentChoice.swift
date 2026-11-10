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

        package var signInCommand: String { signInCommand(executable: nil) }

        /// The sign-in run through the located executable (shell-quoted);
        /// the bare name when none is known.
        package func signInCommand(executable: String?) -> String {
            let program = executable.map { OnboardingAgentChoice.shellQuote($0) } ?? rawValue
            switch self {
            case .claude: return program + " auth login"
            case .codex: return program + " login"
            }
        }

        /// The update for an install too old for `signInCommand`, by how it
        /// was installed (owner, ask #1163): each way updates its own copy;
        /// an unknown way gets no command — the owner updates it their way.
        package func updateCommand(_ kind: InstallKind, executable: String? = nil) -> String? {
            switch (self, kind) {
            case (.claude, .native): executable.map { OnboardingAgentChoice.shellQuote($0) + " update" } ?? "claude update"
            case (.claude, .homebrew): "brew upgrade --cask claude-code"
            case (.claude, .npm): "npm install -g @anthropic-ai/claude-code@latest"
            case (.codex, .native): "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
            case (.codex, .homebrew): "brew upgrade --cask codex"
            case (.codex, .npm): "npm install -g @openai/codex@latest"
            case (_, .unknown): nil
            }
        }

        /// Whether the CLI has the login command, read from the text of
        /// `claude auth --help` / `codex login --help` — never the exit code:
        /// an old CLI may print its general help and exit 0 (owner, ask #1163).
        package func loginSupported(help: String) -> Bool {
            switch self {
            case .claude:
                // The `auth` command list has a `login` row: "  login [options]  Sign in…".
                help.split(separator: "\n").contains { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return line.first == " " && (trimmed == "login" || trimmed.hasPrefix("login "))
                }
            case .codex:
                help.contains("Usage: codex login")
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

    /// How a CLI got onto the Mac, from its executable with symlinks
    /// resolved: it decides the update command.
    package enum InstallKind: Equatable, Sendable {
        /// The vendor's installer (`claude.ai/install.sh`, `codex/install.sh`).
        case native
        case homebrew
        case npm
        case unknown

        package static func of(_ agent: Agent, resolvedPath path: String, home: String) -> Self {
            // Claude Code's old local install keeps npm's folder under
            // ~/.claude/local; `claude update` updates it in place.
            if agent == .claude, path.hasPrefix(home + "/.claude/local/") { return .native }
            if path.contains("/node_modules/") { return .npm }
            if path.contains("/Caskroom/") || path.contains("/Cellar/") { return .homebrew }
            let nativeRoots = switch agent {
            case .claude: [home + "/.local/share/claude/"]
            // install.sh links ~/.local/bin/codex to
            // ~/.codex/packages/standalone/current/bin/codex (rust-v0.166).
            case .codex: [home + "/.codex/packages/standalone/"]
            }
            return nativeRoots.contains { path.hasPrefix($0) } ? .native : .unknown
        }
    }

    /// The resolved executable of an installed agent and how it got there.
    package struct Install: Equatable, Sendable {
        /// Symlinks resolved: decides the kind and names the stuck note.
        package var path: String
        package var kind: InstallKind
        /// Go's own lookup result, what actually runs (the terminal quotes it).
        package var executable: String
        package init(path: String, kind: InstallKind, executable: String? = nil) {
            self.path = path
            self.kind = kind
            self.executable = executable ?? path
        }
    }

    /// Single-quotes a path for the shell; an embedded `'` becomes `'\''`.
    package static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
    /// Signed-out agents whose CLI has no login command yet (the help
    /// probe): the terminal runs the update first, then the sign-in.
    package private(set) var outdated: Set<Agent> = []
    package var installs: [Agent: Install] = [:]
    /// Agents whose update already ran to exit 0 once: still outdated after
    /// it means another copy is in the way, so no second update is offered.
    package private(set) var updateTried: Set<Agent> = []
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
              !signInOpened.contains(agent), terminalCommand != nil else { return nil }
        return agent
    }

    /// What the panel's terminal runs for the picked agent; nil when an
    /// outdated CLI can't be updated from here (`updateStuck`).
    package var terminalCommand: String? {
        guard let agent = selected, status(agent) == .signedOut else { return nil }
        guard outdated.contains(agent) else { return signInCommand(agent) }
        return updateStuck(agent) ? nil : updateCommand(agent)
    }

    private func updateCommand(_ agent: Agent) -> String? {
        agent.updateCommand(installs[agent]?.kind ?? .unknown, executable: installs[agent]?.executable)
    }

    private func signInCommand(_ agent: Agent) -> String {
        agent.signInCommand(executable: installs[agent]?.executable)
    }

    /// Outdated, and either the way it was installed is unknown or an
    /// update already ran without fixing it.
    package func updateStuck(_ agent: Agent) -> Bool {
        outdated.contains(agent) && (updateTried.contains(agent) || updateCommand(agent) == nil)
    }

    /// The help probe's result after a check. An agent that stops being
    /// outdated after its update gets its sign-in opened by itself again.
    package mutating func applyLoginProbe(outdated newOutdated: Set<Agent>) {
        for agent in outdated.subtracting(newOutdated) where updateTried.contains(agent) {
            signInOpened.remove(agent)
            updateTried.remove(agent)
        }
        outdated = newOutdated
    }

    package mutating func signInStarted() {
        guard let selected else { return }
        signIn = .running
        signInOpened.insert(selected)
    }

    /// The process ended; `0` means signed in — the caller checks again.
    package mutating func signInEnded(exitCode: Int32) {
        signIn = exitCode == 0 ? .idle : .ended(exitCode)
        // A finished update: the caller probes again (`applyLoginProbe`).
        if exitCode == 0, let agent = selected, outdated.contains(agent) {
            updateTried.insert(agent)
        }
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
        case .signedOut where updateStuck(agent):
            return Setup(
                agent: agent,
                title: "Update \(agent.name) to sign in",
                steps: [],
                detail: nil,
                showsManualPath: true,
                docsURL: agent.installDocsURL,
                runsSignIn: false,
                signInNote: stuckLine(agent),
                signInNoteWarns: true
            )
        case .signedOut:
            let updating = outdated.contains(agent)
            return Setup(
                agent: agent,
                title: updating ? "Update \(agent.name) to sign in" : "Sign in to \(agent.name)",
                steps: [Step(
                    label: "Or run it in your own Terminal:",
                    command: updating ? updateCommand(agent) : signInCommand(agent)
                )],
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

    private func stuckLine(_ agent: Agent) -> String {
        let path = installs[agent]?.path ?? agent.signInCommand
        if updateTried.contains(agent) {
            return "Updating didn’t change the \(agent.name) Watchtower uses (\(path)). It may be installed twice. "
                + "Update that copy the way you installed it, or choose another executable."
        }
        return "Watchtower can’t tell how this \(agent.name) was installed (\(path)). "
            + "Update it the way you installed it, then check again."
    }

    /// The line above the sign-in terminal.
    private var signInLine: String {
        if let agent = selected, outdated.contains(agent), !isEnded {
            return "This \(agent.name) is too old to sign in from here. It updates first; sign-in starts right after."
        }
        switch signIn {
        case .idle, .running:
            return "Your browser opens to sign in. When it’s done, this closes and Watchtower checks again."
        case .ended(let code):
            let what = selected.map { outdated.contains($0) } == true ? "Update" : "Sign-in"
            return "\(what) stopped before it finished" + (code.map { " (exit code \($0))." } ?? ".")
        }
    }

    private var isEnded: Bool {
        if case .ended = signIn { return true }
        return false
    }

    package static let signInAgain = "Sign in again"
    package static let updateAgain = "Update again"

    /// The button that reruns the terminal after it ended.
    package var retryLabel: String {
        guard let agent = selected, outdated.contains(agent) else { return Self.signInAgain }
        return Self.updateAgain
    }
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
            // Go's text names Codex even for Claude: always our own words.
            return "\(agent.name) answered but ignored Watchtower’s instructions. Update it and check again."
        default:
            let tail = error.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
            return "\(agent.name) didn’t answer\(tail). Run it once in Terminal to see what it says, then check again."
        }
    }

    package static let saveFailure = "Couldn’t save the AI agent."
}

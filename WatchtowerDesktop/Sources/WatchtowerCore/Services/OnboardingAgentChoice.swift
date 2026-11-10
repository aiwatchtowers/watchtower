import Foundation

/// The Goals step's AI agent section (#1521): which CLI Watchtower runs on,
/// picked by the owner. Pure state + every line of copy the section shows;
/// the view only lays it out. Spec:
/// `docs/superpowers/specs/2026-11-10-onboarding-agent-choice-design.md`.
package struct OnboardingAgentChoice: Equatable, Sendable {
    /// The agent kinds the section offers; every per-agent value is the
    /// kind's adapter's `AgentSetup` (LLMTRANSPORT-01, ask #1211).
    package typealias Agent = AgentKind

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
        /// A Homebrew cask (`/Caskroom/`): `brew upgrade --cask <name>`.
        case homebrewCask
        /// A Homebrew formula (`/Cellar/`): `brew upgrade <name>`, only for
        /// an agent Homebrew ships as a formula.
        case homebrewFormula
        case npm
        case unknown

        package static func of(_ agent: Agent, resolvedPath path: String, home: String) -> Self {
            // The installer's own folders first: an old local install keeps
            // npm's folder under one and still updates itself.
            if agent.session.setup.nativeRoots.contains(where: { path.hasPrefix(home + "/" + $0) }) { return .native }
            if path.contains("/node_modules/") { return .npm }
            if path.contains("/Caskroom/") { return .homebrewCask }
            if path.contains("/Cellar/") { return .homebrewFormula }
            return .unknown
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
        /// A check is in flight: the panel's buttons that start one more
        /// (Check again, Sign in again, Choose the executable…) wait for it.
        package var busy = false
        package static let docsLink = "Other ways to install"
        package static let checkAgain = "Check again"
        package static let manualPath = "Choose the executable…"
        package static let autoCheck = "Watchtower checks again when you come back to this window."
        /// The error line when Choose the executable… could not write the config.
        package static let pathSaveFailure = "Couldn’t save the executable’s path."
        /// The open panel's message for Choose the executable….
        package static func choosePanelMessage(_ agent: Agent) -> String {
            "Select the \(agent.productName) executable"
        }
    }

    package var statuses: [Agent: Status]
    package private(set) var signIn: SignIn = .idle
    /// A per-agent check runs (the first one, or a recheck after a sign-in,
    /// Check again, reactivation, Choose the executable…): the tiles show
    /// Checking… instead of the last result, so nothing invites a second
    /// sign-in while the first one's result is on its way.
    package private(set) var checkInFlight = false
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

    /// A check started; `checkFinished` lands its result.
    package mutating func checkStarted() { checkInFlight = true }
    package mutating func checkFinished() { checkInFlight = false }

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

    /// The owner left the step with the terminal running (its process is
    /// gone): no longer running, and not the owner's Stop either — on return
    /// the panel reads as an already-opened sign-in waiting for a press.
    package mutating func signInLeft() {
        guard signIn == .running else { return }
        signIn = .idle
    }

    /// After a check: a running sign-in whose agent is no longer signed out
    /// (signed in elsewhere, gone, or another agent picked) is over — the
    /// caller closes its terminal.
    package mutating func settleSignIn() {
        guard signIn == .running, selected.map(status) != .signedOut else { return }
        signIn = .idle
    }

    /// The tiles show unless a working provider was set elsewhere.
    package var showsTiles: Bool { otherProvider == nil || otherProviderFailure != nil }

    package var canContinue: Bool {
        if otherProvider != nil, otherProviderFailure == nil { return true }
        guard let selected else { return false }
        return status(selected) == .ready
    }

    package var isChecking: Bool {
        checkInFlight || Agent.allCases.contains { status($0) == .checking }
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
        // A recheck shows as checking: the last result may be about to change.
        let state = checkInFlight && status(agent) != .forbidden ? .checking : status(agent)
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
            title: agent.productName,
            status: text,
            tone: tone,
            busy: state == .checking,
            selected: selected == agent,
            enabled: state != .forbidden
        )
    }

    package var setup: Setup? {
        guard var panel = basePanel else { return nil }
        guard checkInFlight else { return panel }
        panel.busy = true
        if panel.runsSignIn, signIn != .running {
            // The last result's line ("Your browser opens…") would be stale.
            panel.signInNote = Self.rechecking(panel.agent)
            panel.signInNoteWarns = false
        }
        return panel
    }

    private var basePanel: Setup? {
        guard showsTiles, let agent = selected else { return nil }
        switch status(agent) {
        case .checking, .ready, .forbidden:
            return nil
        case .notInstalled:
            return Setup(
                agent: agent,
                title: "Install \(agent.productName)",
                steps: [
                    Step(label: "Install it in Terminal:", command: agent.session.setup.installCommand),
                    Step(label: "Sign in:", command: agent.signInCommand)
                ],
                detail: nil,
                showsManualPath: true,
                docsURL: agent.session.setup.installDocsURL,
                runsSignIn: false
            )
        case .signedOut where updateStuck(agent):
            return Setup(
                agent: agent,
                title: "Update \(agent.productName) to sign in",
                steps: [],
                detail: nil,
                showsManualPath: true,
                docsURL: agent.session.setup.installDocsURL,
                runsSignIn: false,
                signInNote: stuckLine(agent),
                signInNoteWarns: true
            )
        case .signedOut:
            let updating = outdated.contains(agent)
            return Setup(
                agent: agent,
                title: updating ? "Update \(agent.productName) to sign in" : "Sign in to \(agent.productName)",
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
                title: "\(agent.productName) didn’t answer",
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
            return "Updating didn’t change the \(agent.productName) Watchtower uses (\(path)). It may be installed twice. "
                + "Update that copy the way you installed it, or choose another executable."
        }
        return "Watchtower can’t tell how this \(agent.productName) was installed (\(path)). "
            + "Update it the way you installed it, then check again."
    }

    /// The line above the sign-in terminal.
    private var signInLine: String {
        if let agent = selected, outdated.contains(agent), !isEnded {
            return "This \(agent.productName) is too old to sign in from here. It updates first; sign-in starts right after."
        }
        switch signIn {
        case .idle where selected.map(signInOpened.contains) == true:
            // Opened before (the owner switched tiles or left the step and
            // came back): nothing opens by itself any more.
            return Self.pressToSignIn
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
    /// The note of an already-opened, idle sign-in (M4).
    package static let pressToSignIn = "Press Sign in again to open the sign-in here."

    /// The sign-in panel's note while a check runs.
    package static func rechecking(_ agent: Agent) -> String {
        "Checking \(agent.productName) again…"
    }
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
        return "Continue unlocks once \(selected.productName) is ready"
    }

    /// The Development goal's pitch names the agent that will work the board.
    package var developmentPitch: String {
        let name = (showsTiles ? selected?.productName : nil) ?? "Your AI agent"
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
            return "Couldn’t reach \(agent.productName)’s service. Check the network or VPN, then check again."
        case "invalid_output":
            // Go's text names Codex even for Claude: always our own words.
            return "\(agent.productName) answered but ignored Watchtower’s instructions. Update it and check again."
        default:
            let tail = error.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
            return "\(agent.productName) didn’t answer\(tail). Run it once in Terminal to see what it says, then check again."
        }
    }

    /// The Failed line when Watchtower's own lookup (`ai which`) could not
    /// answer — never "Not installed", which would send the owner to
    /// install a CLI that may be there.
    package static func lookupFailureMessage(_ agent: Agent, error: String?) -> String {
        let tail = error.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
        return "Watchtower couldn’t look for \(agent.productName)\(tail). "
            + "Check that Watchtower’s config file is readable, then check again."
    }

    /// The failure line of that provider's test (the caption wraps it).
    package static func otherFailureLine(code: String?, error: String?) -> String {
        switch code {
        case "transport", "timeout": "Couldn’t reach it."
        default: "It didn’t pass the check."
        }
    }

    package static let saveFailure = "Couldn’t save the AI agent."
}

extension AgentKind {
    /// The tile title, from the kind's adapter.
    package var productName: String { session.setup.productName }

    /// The sign-in with the bare name, before an executable is known.
    package var signInCommand: String { signInCommand(executable: nil) }

    /// The sign-in run through the located executable (shell-quoted);
    /// the bare name when none is known.
    package func signInCommand(executable: String?) -> String {
        ([program(executable)] + session.setup.signInArguments).joined(separator: " ")
    }

    /// The update for an install too old for `signInCommand`, by how it
    /// was installed (owner, ask #1163): each way updates its own copy;
    /// an unknown way gets no command — the owner updates it their way.
    package func updateCommand(_ kind: OnboardingAgentChoice.InstallKind, executable: String? = nil) -> String? {
        switch session.setup.updates[kind] {
        case .runExecutable(let arguments): ([program(executable)] + arguments).joined(separator: " ")
        case .literal(let command): command
        case nil: nil
        }
    }

    /// Whether the CLI has the login command, read from the help text
    /// (`AgentSetup.loginHelpArguments`) — never the exit code: an old CLI
    /// may print its general help and exit 0 (owner, ask #1163).
    package func loginSupported(help: String) -> Bool {
        session.setup.loginSupported(help: help)
    }

    private func program(_ executable: String?) -> String {
        executable.map { OnboardingAgentChoice.shellQuote($0) } ?? rawValue
    }
}

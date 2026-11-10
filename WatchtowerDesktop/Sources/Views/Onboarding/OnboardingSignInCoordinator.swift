import AppKit
import Observation
import WatchtowerCore

/// What the coordinator drives: `OnboardingSignInSession` in the app, a
/// fake in tests.
@MainActor
protocol OnboardingSignInRunning: AnyObject {
    var isRunning: Bool { get }
    func start(command: String)
    func stop()
}

extension OnboardingSignInSession: OnboardingSignInRunning {}

/// The Goals step's side effects around the AI agent section (#1521): the
/// sign-in / update terminal (opened by itself once, rerun by the owner,
/// stopped by Stop, a tile switch, leaving the step and app quit) and
/// Choose the executable…. Owned by the step view; the state lives in
/// `OnboardingGoalsModel`.
@MainActor
@Observable
final class OnboardingSignInCoordinator {
    typealias Agent = OnboardingAgentChoice.Agent
    typealias MakeSession = @MainActor (
        _ environment: [String: String],
        _ onExit: @escaping (Int32) -> Void
    ) -> any OnboardingSignInRunning

    /// Choose the executable… could not write the config.
    private(set) var pathError: String?

    @ObservationIgnored let model: OnboardingGoalsModel
    @ObservationIgnored private let environment: () async -> [String: String]
    @ObservationIgnored private let makeSession: MakeSession
    @ObservationIgnored private let configPath: String
    @ObservationIgnored private let pickExecutable: @MainActor (Agent) -> String?
    /// The terminal of the last run; the view shows it.
    private(set) var session: (any OnboardingSignInRunning)?
    /// The model's handling of the last exit (recheck, then maybe the next
    /// terminal); tests await it.
    @ObservationIgnored private(set) var exitHandling: Task<Void, Never>?
    /// The open that made `session`.
    @ObservationIgnored private var sessionRun = 0
    /// The login-shell environment, resolved once.
    @ObservationIgnored private var resolvedEnv: [String: String]?
    /// Bumped by every open and stop: an open still resolving the
    /// environment when a stop comes starts nothing.
    @ObservationIgnored private var generation = 0
    /// `nonisolated(unsafe)`: set once in init, read by deinit.
    @ObservationIgnored nonisolated(unsafe) private var terminateObserver: NSObjectProtocol?

    init(
        model: OnboardingGoalsModel,
        environment: @escaping () async -> [String: String] = { await Constants.resolvedEnvironmentAsync() },
        makeSession: @escaping MakeSession = { OnboardingSignInSession(environment: $0, onExit: $1) },
        configPath: String = Constants.configPath,
        pickExecutable: @escaping @MainActor (Agent) -> String? = OnboardingSignInCoordinator.openPanel(for:)
    ) {
        self.model = model
        self.environment = environment
        self.makeSession = makeSession
        self.configPath = configPath
        self.pickExecutable = pickExecutable
        // No queue: the block runs inside the post, before the app exits
        // (deinit does not run on quit). The notification comes on the main
        // thread.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    deinit {
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
    }

    /// The model's agent needs its terminal opened by itself (the first
    /// time it shows as signed out, or after an update fixed it).
    func openIfNeeded() async {
        guard model.agentChoice.signInToOpen != nil else { return }
        await open()
    }

    /// Runs the picked agent's terminal command: the auto-open, Sign in
    /// again and Update again. Every run gets a fresh terminal (a PTY is
    /// never restarted in place).
    func open() async {
        guard let command = model.agentChoice.terminalCommand else { return }
        model.signInStarted()
        generation += 1
        let run = generation
        let env = await resolvedEnvironment()
        guard run == generation, model.agentChoice.signIn == .running else { return }
        session?.stop()
        sessionRun = run
        let made = makeSession(env) { [weak self] code in
            // Only the current terminal's exit counts.
            guard let self, self.sessionRun == run else { return }
            self.exited(code)
        }
        session = made
        made.start(command: command)
    }

    /// The owner pressed Stop.
    func stopByOwner() {
        stop()
        model.signInStopped()
    }

    /// A tile tap: the other agent's tile stops a running terminal first.
    func pick(_ agent: Agent) {
        pathError = nil
        if agent != model.agentChoice.selected, model.agentChoice.status(agent) != .forbidden {
            stop()
        }
        model.pickAgent(agent)
    }

    /// Check again. The tile may turn Ready while the sign-in runs: its
    /// terminal closes.
    func checkAgain() async {
        pathError = nil
        await model.runAgentCheck()
        closeIfSettled()
    }

    /// The model no longer runs a sign-in (a check settled it): a terminal
    /// still going is stopped.
    func closeIfSettled() {
        guard model.agentChoice.signIn != .running, session?.isRunning == true else { return }
        stop()
    }

    /// Ends the process only (leaving the step, Cancel, app quit): the model
    /// is not told, nothing shows the terminal any more.
    func stop() {
        generation += 1
        session?.stop()
    }

    /// Choose the executable…: the picked file becomes the agent's
    /// `claude_path` / `codex_path`, then the agents are checked again.
    func chooseExecutable(for agent: Agent) async {
        guard let path = pickExecutable(agent) else { return }
        do {
            try OnboardingAgentPathConfig.save(path, for: agent, configPath: configPath)
        } catch {
            pathError = OnboardingAgentChoice.Setup.pathSaveFailure + " " + error.localizedDescription
            return
        }
        pathError = nil
        await model.runAgentCheck()
        closeIfSettled()
    }

    private func resolvedEnvironment() async -> [String: String] {
        if let resolvedEnv { return resolvedEnv }
        let env = await environment()
        resolvedEnv = env
        return env
    }

    /// The recheck after an exit can take seconds: a stop in the meantime
    /// (the step left, Cancel, quit, another tile) means no new terminal.
    private func exited(_ code: Int32) {
        let run = generation
        exitHandling = Task { [weak self, model] in
            await model.signInEnded(exitCode: code)
            guard let self, run == self.generation else { return }
            await self.openIfNeeded()
        }
    }

    static func openPanel(for agent: Agent) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = OnboardingAgentChoice.Setup.choosePanelMessage(agent)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

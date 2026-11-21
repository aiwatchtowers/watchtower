import Foundation
import Observation

/// One service's connect assistant (agent connect spec §5.2, §7, §8): the
/// panel's state, and the runs it starts. A run is one per-run socket
/// (`ConnectRunServer`), one `ConnectRunController` and one in-memory
/// embedded chat whose turns run `ai query --tools connect` on the chosen
/// harness. Every run starts from `connect_status`, so Retry, a harness
/// switch and reopening the panel all resume from the driver's state; the
/// chat itself is not kept (`.memory`, no owner instructions).
///
/// Ends of a run (`close`, `cancel`, `retry`, `switchHarness`): the
/// controller's `end()` answers held calls `closed`, the socket stops, the
/// chat's turn stops (its process is ended), and a probe still running is
/// cancelled. A flow on the driver keeps today's behaviour (§8). Callbacks
/// of an ended run are dropped: each carries its run number.
@MainActor
@Observable
package final class ConnectAssistantSession {
    /// The customer's first turn: they pressed Start.
    package static let startPrompt = "Start"

    package let service: String
    /// The connector's display name ("Slack").
    package let displayName: String
    /// The offered harnesses (`ConnectHarnessCatalog.offered(...).harnesses`), for the header's picker.
    package let harnesses: [ConnectHarness]
    package private(set) var harness: ConnectHarness
    /// False once the probe or a browser tool said the extension is not connected.
    package private(set) var browserAvailable = true
    /// The current run's chat; the last run's after Cancel, nil after Close.
    package private(set) var engine: EmbeddedChatEngine?
    /// The current run's rules; the panel's cards answer through it.
    package private(set) var controller: ConnectRunController?

    private enum Phase { case idle, starting, running }

    private var phase = Phase.idle
    /// The customer chose Guide me in words.
    private var wordsChosen = false
    private var runFailure: ConnectAssistantFailure?
    @ObservationIgnored private var server: ConnectRunServer?
    @ObservationIgnored private var run = 0
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var statusJSON = "{}"
    /// The running turn's browser steps, by step id.
    @ObservationIgnored private var browserSteps: Set<String> = []

    @ObservationIgnored private let driver: any ConnectServiceDriving
    @ObservationIgnored private let aiService: any AIServiceProtocol
    @ObservationIgnored private let probe: ConnectBrowserProbe
    @ObservationIgnored private let gate: EmbeddedStreamGate

    package init(
        service: String,
        displayName: String,
        harnesses: [ConnectHarness],
        initial: ConnectHarness,
        driver: any ConnectServiceDriving,
        aiService: any AIServiceProtocol,
        probe: ConnectBrowserProbe,
        gate: EmbeddedStreamGate
    ) {
        self.service = service
        self.displayName = displayName
        self.harnesses = harnesses
        harness = initial
        self.driver = driver
        self.aiService = aiService
        self.probe = probe
        self.gate = gate
    }

    // MARK: - What the panel shows

    /// Browser only when the customer did not ask for words, the harness can
    /// drive a browser and the extension was not found missing.
    package var mode: ConnectAssistantMode {
        !wordsChosen && browserAvailable && harness.capability == .browser ? .browser : .words
    }

    package var state: ConnectAssistantState {
        if phase == .idle { return .empty }
        if let runFailure { return .failed(runFailure) }
        if let controllerState = controller?.state, controllerState != .thinking { return controllerState }
        if phase == .starting || engine?.isBusy == true || engine?.isFinishing == true { return .thinking }
        return .listening
    }

    package var presentation: ConnectAssistantPresentation {
        ConnectAssistantPresentation(service: displayName, harness: harness, mode: mode,
                                     browserAvailable: browserAvailable, state: state)
    }

    // MARK: - Panel actions

    /// Starts a run: the socket, a fresh controller, `connect_status`, the
    /// browser probe (browser mode only), then the chat's first turn.
    package func start() {
        guard phase == .idle else { return }
        engine = nil
        run += 1
        let run = run
        runFailure = nil
        browserSteps = []
        let controller = ConnectRunController(driver: driver)
        // Weak: the server's handlers must not keep the run alive (Task 8).
        let server = ConnectRunServer(service: service) { [weak controller] request in
            guard let controller else {
                return ConnectWireResponse(id: request.id, error: .closed,
                                           message: Self.runEndedMessage)
            }
            return await controller.handle(request)
        }
        self.controller = controller
        phase = .starting
        do {
            _ = try server.start()
        } catch {
            phase = .running
            runFailure = .agent(reason: Self.socketFailedMessage)
            return
        }
        self.server = server
        startTask = Task { [weak self, weak server] in
            await self?.prepare(run: run, environment: server?.environment ?? [:])
        }
    }

    /// Guide me in words: a run that never drives the browser.
    package func guideInWords() {
        guard phase == .idle else { return }
        wordsChosen = true
        start()
    }

    /// Another harness from the picker: the run ends and the panel waits for
    /// Start again. Nothing switches by itself (spec §8: tool turns are not
    /// replay-safe).
    package func switchHarness(_ next: ConnectHarness) {
        guard next != harness, harnesses.contains(next) else { return }
        endRun()
        harness = next
        wordsChosen = false
        browserAvailable = true
        phase = .idle
    }

    /// A fresh run after a failure: new socket, new controller (a timed-out
    /// one refuses every wait), and the state read again.
    package func retry() {
        endRun()
        phase = .idle
        start()
    }

    /// Cancel while the agent works: the run ends, its chat stays in view.
    package func cancel() {
        endRun()
        phase = .idle
    }

    /// The panel closed, or the app quits: the run ends and its chat goes.
    /// Reopening starts a new run from `connect_status`.
    package func close() {
        endRun()
        engine = nil
        phase = .idle
        wordsChosen = false
    }

    /// Returns once a started run's first turn is under way (or the run
    /// ended first).
    package func prepared() async {
        await startTask?.value
    }

    // MARK: - Run

    private func prepare(run: Int, environment: [String: String]) async {
        let status = await driver.status()
        guard run == self.run else { return }
        statusJSON = Self.json(status)
        if mode == .browser {
            let probed = await probe.mode(for: harness, service: service, environment: environment)
            guard run == self.run else { return }
            if probed == .words { browserAvailable = false }
        }
        startTask = nil
        let engine = EmbeddedChatEngine(spec: spec(), store: MemoryEmbeddedChatStore(), aiService: aiService,
                                        gate: gate, provider: harness.id)
        engine.onToolEvent = { [weak self] event in self?.observe(event, run: run) }
        engine.onTurnFinished = { [weak self] outcome in self?.turnFinished(outcome, run: run) }
        self.engine = engine
        phase = .running
        engine.send(Self.startPrompt)
    }

    private func spec() -> ChatSurfaceSpec {
        let status = statusJSON
        let provider = harness.id
        return ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: "connect", contextID: service, conversationID: nil),
            persistence: .memory,
            toolAccess: .connect(service: service, mode: mode),
            ownerInstructions: false,
            systemPrompt: { Self.systemPrompt(status: status) },
            emptyHint: "",
            // Always the chosen harness: a connect turn is never routed.
            runOptions: { ChatRunOptions(provider: provider) },
            extraEnvironment: { [weak server] in server?.environment ?? [:] }
        )
    }

    /// A browser tool whose result says the extension is gone: the rest of
    /// the run is in words (§8) — not an error. The agent is told in a
    /// hidden turn once the current one ends.
    private func observe(_ event: StreamEvent, run: Int) {
        guard run == self.run else { return }
        switch event {
        case .toolStart(let start) where ConnectBrowserProbe.isBrowserTool(start.name):
            browserSteps.insert(start.id)
        case .toolEnd(let end) where browserSteps.contains(end.id):
            browserSteps.remove(end.id)
            guard ConnectBrowserProbe.browserLost(end), mode == .browser else { return }
            browserAvailable = false
            engine?.update(spec: spec())
            engine?.sendFollowUp(prompt: ConnectBrowserProbe.lostFollowUp)
        default:
            break
        }
    }

    private func turnFinished(_ outcome: EmbeddedChatEngine.TurnOutcome, run: Int) {
        guard run == self.run else { return }
        switch outcome {
        case .failed:
            runFailure = Self.failure(engine?.lastFailure)
        case .notStarted(let message):
            runFailure = .agent(reason: message)
        case .completed:
            runFailure = nil
        case .stopped:
            break
        }
    }

    private func endRun() {
        run += 1
        startTask?.cancel()  // a probe's stream ends, and its process with it
        startTask = nil
        controller?.end()
        controller = nil
        server?.stop()
        server = nil
        engine?.shutdown(quietly: true)
        browserSteps = []
        runFailure = nil
    }

    // MARK: - Strings and mapping

    static let runEndedMessage = "this run has ended"
    static let socketFailedMessage = "Couldn't open the assistant's line to Watchtower."

    /// Watchtower's part of the run's system prompt (the CLI puts the connect
    /// prompt and the playbook before it): the state the playbook resumes from.
    package static func systemPrompt(status: String) -> String {
        "The current state from connect_status, read when this run started:\n\(status)\n"
            + "Resume the playbook from this state."
    }

    /// A failed turn as the panel's failure: the harness's usage limit, its
    /// CLI missing, or the agent's own words.
    package static func failure(_ failure: EmbeddedChatErrorClassifier.Failure?) -> ConnectAssistantFailure {
        guard let failure else { return .agent(reason: nil) }
        switch failure.code {
        case .quotaExhausted, .rateLimit:
            return .quota
        case .providerUnavailable where missingPhrases.contains(where: failure.message.lowercased().contains):
            return .harnessMissing
        default:
            return .agent(reason: failure.message)
        }
    }

    /// What a missing CLI says: the app's own (`WatchtowerAIError.cliNotFound`
    /// and `.launchFailed`), or the harness binary not found on PATH.
    private static let missingPhrases = [
        "cli not found", "couldn't start the watchtower cli", "executable file not found",
        "command not found", "no such file or directory", "not installed"
    ]

    private static func json(_ status: ConnectStatus) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(status)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
    }
}

/// The connect assistants of the app, one per service, so reopening the
/// panel (or a second entry point) shows the same session.
@MainActor
package final class ConnectAssistantCenter {
    /// Builds a service's session (its driver, harnesses and probe); nil when
    /// the service offers no assistant.
    package typealias SessionFactory = @MainActor (String) -> ConnectAssistantSession?

    private var sessions: [String: ConnectAssistantSession] = [:]
    private let makeSession: SessionFactory

    package init(makeSession: @escaping SessionFactory) {
        self.makeSession = makeSession
    }

    package func session(for service: String) -> ConnectAssistantSession? {
        if let session = sessions[service] { return session }
        let session = makeSession(service)
        sessions[service] = session
        return session
    }

    /// App quit: every run ends (its held calls answer `closed`, the sockets
    /// close, the chats stop).
    package func closeAll() {
        for session in sessions.values { session.close() }
    }
}

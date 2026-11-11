import AppKit
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// #1521: the Goals step's sign-in terminal and Choose the executable…,
/// through `OnboardingSignInCoordinator` with a fake terminal (no process).
@MainActor
final class OnboardingGoalsStepTests: XCTestCase {
    private typealias Choice = OnboardingAgentChoice

    /// A terminal that records what it was asked to do.
    @MainActor
    private final class FakeSession: OnboardingSignInRunning {
        let onExit: (Int32) -> Void
        var commands: [String] = []
        var stops = 0
        var isRunning = false

        init(onExit: @escaping (Int32) -> Void) { self.onExit = onExit }

        func start(command: String) {
            commands.append(command)
            isRunning = true
        }

        func stop() {
            stops += 1
            isRunning = false
        }

        /// The process ended by itself.
        func exit(_ code: Int32) {
            isRunning = false
            onExit(code)
        }
    }

    @MainActor
    private final class Fakes {
        var result = OnboardingAgentCheckResult()
        var sessions: [FakeSession] = []
        var picked: String?
        /// Set: the next check waits for `releaseCheck()`.
        var holdChecks = false
        private var held: CheckedContinuation<Void, Never>?

        func check() async -> OnboardingAgentCheckResult {
            if holdChecks { await withCheckedContinuation { held = $0 } }
            return result
        }

        var isHolding: Bool { held != nil }

        func releaseCheck() {
            held?.resume()
            held = nil
        }
    }

    private var fakes = Fakes()
    private var configDir: URL!

    override func setUp() async throws {
        fakes = Fakes()
        configDir = FileManager.default.temporaryDirectory.appendingPathComponent("goals-step-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: configDir)
    }

    private var configPath: String { configDir.appendingPathComponent("config.yaml").path }
    /// Overrides `configPath` for the next `makeCoordinator()`.
    private var configPathOverride: String?

    private func makeCoordinator() -> OnboardingSignInCoordinator {
        let fakes = self.fakes
        let model = OnboardingGoalsModel(
            defaults: AppState.isolatedDefaults,
            systemLanguage: "English",
            checkAgents: { await fakes.check() },
            configuredProvider: { nil },
            actions: OnboardingGoalsActions(initWorkspace: {}, setLanguage: { _ in }, applyFeatures: { _ in (nil, false) })
        )
        let pick: @MainActor (Choice.Agent) -> String? = { _ in fakes.picked }
        return OnboardingSignInCoordinator(
            model: model,
            environment: { [:] },
            makeSession: { _, onExit in
                let session = FakeSession(onExit: onExit)
                fakes.sessions.append(session)
                return session
            },
            configPath: configPathOverride ?? configPath,
            pickExecutable: pick
        )
    }

    private static let claudeSignedOut = OnboardingAgentCheckResult(statuses: [.claude: .signedOut, .codex: .notInstalled])

    /// A coordinator whose model shows Claude signed out and its sign-in running.
    private func runningSignIn() async throws -> (OnboardingSignInCoordinator, FakeSession) {
        fakes.result = Self.claudeSignedOut
        let coordinator = makeCoordinator()
        await coordinator.model.runAgentCheck()
        await coordinator.openIfNeeded()
        let session = try XCTUnwrap(fakes.sessions.first)
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(coordinator.model.agentChoice.signIn, .running)
        return (coordinator, session)
    }

    func testAutoOpensSignInOnce() async throws {
        let (coordinator, session) = try await runningSignIn()
        XCTAssertEqual(session.commands, [Choice.Agent.claude.signInCommand])

        await coordinator.openIfNeeded()
        session.exit(1)
        await coordinator.exitHandling?.value
        await coordinator.openIfNeeded()
        XCTAssertEqual(fakes.sessions.count, 1)
        XCTAssertEqual(coordinator.model.agentChoice.signIn, .ended(1))
    }

    func testAppQuitStopsSignIn() async throws {
        let (coordinator, session) = try await runningSignIn()
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        XCTAssertEqual(session.stops, 1)
        XCTAssertFalse(session.isRunning)
        withExtendedLifetime(coordinator) {}
    }

    /// Leaving the step (onDisappear) ends the process and the model's
    /// running state (M5) — idle and already opened, not the owner's Stop:
    /// on return nothing opens by itself and no Stop warning shows.
    func testLeavingTheStepStopsSignIn() async throws {
        let (coordinator, session) = try await runningSignIn()
        coordinator.leave()
        XCTAssertEqual(session.stops, 1)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(coordinator.model.agentChoice.signIn, .idle)
        XCTAssertEqual(coordinator.model.agentChoice.setup?.signInNote, Choice.pressToSignIn)
        XCTAssertEqual(coordinator.model.agentChoice.setup?.signInNoteWarns, false)
        await coordinator.openIfNeeded()
        XCTAssertEqual(fakes.sessions.count, 1, "returning to the step opens nothing by itself")
    }

    func testStopByOwnerEndsTheSignIn() async throws {
        let (coordinator, session) = try await runningSignIn()
        coordinator.stopByOwner()
        XCTAssertEqual(session.stops, 1)
        XCTAssertEqual(coordinator.model.agentChoice.signIn, .ended(nil))
        await coordinator.openIfNeeded()
        XCTAssertEqual(fakes.sessions.count, 1, "a stopped sign-in never reopens by itself")
    }

    /// Sign in again gets a fresh terminal; the old one's late exit is ignored.
    func testSignInAgainRunsAFreshTerminal() async throws {
        let (coordinator, first) = try await runningSignIn()
        coordinator.stopByOwner()
        await coordinator.open()
        XCTAssertEqual(fakes.sessions.count, 2)
        let second = fakes.sessions[1]
        XCTAssertEqual(second.commands, [Choice.Agent.claude.signInCommand])
        first.exit(1)
        XCTAssertNil(coordinator.exitHandling)
        XCTAssertEqual(coordinator.model.agentChoice.signIn, .running)
    }

    func testPickingTheOtherTileStopsSignIn() async throws {
        let (coordinator, session) = try await runningSignIn()
        coordinator.pick(.claude)
        XCTAssertEqual(session.stops, 0, "the same tile leaves it running")
        coordinator.pick(.codex)
        XCTAssertEqual(session.stops, 1)
        XCTAssertEqual(coordinator.model.agentChoice.selected, .codex)
        XCTAssertEqual(coordinator.model.agentChoice.signIn, .idle)
    }

    func testUpdateThenSignInOpensByItself() async throws {
        let executable = "/Users/acme/.local/bin/claude"
        let install = Choice.Install(
            path: "/Users/acme/.local/share/claude/versions/1.0.88", kind: .native, executable: executable
        )
        fakes.result = OnboardingAgentCheckResult(
            statuses: [.claude: .signedOut, .codex: .notInstalled],
            installs: [.claude: install],
            outdated: [.claude]
        )
        let coordinator = makeCoordinator()
        await coordinator.model.runAgentCheck()
        await coordinator.openIfNeeded()
        let session = try XCTUnwrap(fakes.sessions.first)
        XCTAssertEqual(session.commands, ["'\(executable)' update"])

        fakes.result.outdated = []
        session.exit(0)
        await coordinator.exitHandling?.value
        XCTAssertEqual(fakes.sessions.map(\.commands), [["'\(executable)' update"], ["'\(executable)' auth login"]])
        XCTAssertEqual(coordinator.model.agentChoice.signIn, .running)
    }

    /// An update exits 0; the recheck is slow; the owner leaves the step
    /// before it lands: no sign-in terminal opens afterwards.
    func testLeavingDuringTheRecheckOpensNoTerminal() async throws {
        let install = Choice.Install(path: "/Users/acme/.local/share/claude/versions/1.0.88", kind: .native)
        fakes.result = OnboardingAgentCheckResult(
            statuses: [.claude: .signedOut, .codex: .notInstalled], installs: [.claude: install], outdated: [.claude]
        )
        let coordinator = makeCoordinator()
        await coordinator.model.runAgentCheck()
        await coordinator.openIfNeeded()
        let session = try XCTUnwrap(fakes.sessions.first)

        fakes.holdChecks = true
        fakes.result.outdated = []
        session.exit(0)
        while !fakes.isHolding { await Task.yield() }
        coordinator.leave()
        fakes.releaseCheck()
        await coordinator.exitHandling?.value
        XCTAssertEqual(fakes.sessions.count, 1)
        XCTAssertNotNil(coordinator.model.agentChoice.signInToOpen, "the step opens it when shown again")
    }

    /// Check again finds the agent signed in while its sign-in runs: the
    /// terminal closes and the model leaves `.running`.
    func testCheckAgainReadyClosesTheTerminal() async throws {
        let (coordinator, session) = try await runningSignIn()
        fakes.result = OnboardingAgentCheckResult(statuses: [.claude: .ready, .codex: .notInstalled])
        await coordinator.checkAgain()
        XCTAssertEqual(session.stops, 1)
        XCTAssertEqual(coordinator.model.agentChoice.signIn, .idle)
        XCTAssertTrue(coordinator.model.canContinue)
    }

    func testPathErrorClearsOnTileSwitchAndCheckAgain() async throws {
        let blocker = configDir.appendingPathComponent("file")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try Data().write(to: blocker)
        configPathOverride = blocker.appendingPathComponent("config.yaml").path
        fakes.result = OnboardingAgentCheckResult(statuses: [.claude: .notInstalled, .codex: .notInstalled])
        let coordinator = makeCoordinator()
        await coordinator.model.runAgentCheck()
        fakes.picked = "/opt/acme/bin/claude"

        await coordinator.chooseExecutable(for: .claude)
        XCTAssertNotNil(coordinator.pathError)
        coordinator.pick(.codex)
        XCTAssertNil(coordinator.pathError)

        await coordinator.chooseExecutable(for: .codex)
        XCTAssertNotNil(coordinator.pathError)
        await coordinator.checkAgain()
        XCTAssertNil(coordinator.pathError)
    }

    func testChooseExecutableSavesThePickedAgentsPath() async throws {
        fakes.result = OnboardingAgentCheckResult(statuses: [.claude: .notInstalled, .codex: .notInstalled])
        let coordinator = makeCoordinator()
        await coordinator.model.runAgentCheck()

        fakes.picked = "/opt/acme/bin/codex"
        fakes.result = OnboardingAgentCheckResult(statuses: [.claude: .notInstalled, .codex: .ready])
        await coordinator.chooseExecutable(for: .codex)
        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertEqual(saved, "codex_path: '/opt/acme/bin/codex'\n")
        XCTAssertNil(coordinator.pathError)
        XCTAssertEqual(coordinator.model.agentChoice.status(.codex), .ready, "the agents are checked again")
    }

    func testChooseExecutableCancelledWritesNothing() async {
        let coordinator = makeCoordinator()
        await coordinator.chooseExecutable(for: .claude)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))
    }
}

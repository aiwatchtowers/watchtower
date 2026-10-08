import XCTest
import AppKit
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// A process that records what was typed into it.
@MainActor
private final class LineProbeSession: TerminalSessionProcess {
    let view = NSView()
    let pid: pid_t = 0
    var onExit: ((Int32?) -> Void)?
    var onOwnerInput: (([UInt8]) -> Void)?
    var bracketedPasteMode = true
    private(set) var inputs: [[UInt8]] = []

    func start(_ launch: TerminalLaunch) {}
    func detach() {}
    func sendInput(_ bytes: [UInt8]) { inputs.append(bytes) }
}

/// The state reads' outcome, switched by a test.
private final class ReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = true

    var fails: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func check() throws {
        if fails { throw CancellationError() }
    }
}

/// `SessionLineDelivery` (mobile POC spec §6.6): the one path a line takes
/// into a session's prompt — an ask's answer or another line — under
/// PROJ-12's rules, with one queue per session.
@MainActor
final class SessionLineDeliveryTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var processes: [LineProbeSession] = []
    private var center: TerminalCenter!
    /// Runs in the pause between a line's paste and its Return.
    private var onPause: (() async -> Void)?

    nonisolated private static let questions = #"{"questions":[{"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}]}"#
    private static let otherLine = "Please wrap up: update the board, then call finish_session with a short summary."

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "SessionLineDeliveryTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt lines \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        processes = []
        onPause = nil
        center = TerminalCenter(
            makeProcess: { [weak self] in
                let process = LineProbeSession()
                self?.processes.append(process)
                return process
            },
            signaller: ProcessGroupSignaller(
                signal: { _, _ in }, isAlive: { _ in false },
                sleep: { [weak self] _ in await self?.onPause?() }
            )
        )
        center.shell = { "/bin/zsh" }
        center.copyToClipboard = { _ in }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private var typed: [[UInt8]] { processes.flatMap(\.inputs) }
    private var typedText: [String] { typed.map { String(bytes: $0, encoding: .utf8) ?? "" } }

    /// Hooks reported this run and every read fresh, so a line may be
    /// submitted; the held hint's wait never ends by itself.
    private func makeVM(agentStates: SessionAgentStateCenter? = nil) -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: center, agentStates: agentStates)
        vm.asks.holdSleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
        if agentStates == nil {
            vm.lineDelivery.hasHookState = { _ in true }
            vm.lineDelivery.refreshStates = { true }
        }
        return vm
    }

    /// A workbench with one running shell session and an open ask from it.
    private func seed() async throws -> (project: Int64, session: TerminalSession, ask: Int64) {
        let acme = folder.path
        let seeded = try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, folder: acme)
            let s = try TerminalSessionQueries.create(d, .init(projectID: p, kind: .shell, title: "zsh", folderPath: acme))
            let ask = try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s.id, payload: Self.questions)
            return (p, s, ask)
        }
        center.start(seeded.1, fresh: true)
        return seeded
    }

    private func answerableAsk(_ vm: WorkbenchesViewModel, project: Int64, id: Int64) async throws -> OwnerAsk {
        await vm.asks.load(projectID: project)
        vm.asks.drafts.update(id) { $0.picks["a"] = .init(labels: ["Yes"]) }
        return try XCTUnwrap(vm.asks.openAsks[project]?.first { $0.id == id })
    }

    /// One queue per session: an ask's answer written while another line is
    /// in its pause waits, then goes on its own — each line pasted and
    /// submitted in turn, never two in one prompt.
    func testAnAskAnswerDuringAnotherLinesPauseGoesAfterIt() async throws {
        let (p, s, askID) = try await seed()
        let vm = makeVM()
        let ask = try await answerableAsk(vm, project: p, id: askID)
        var answered: OwnerAsksViewModel.Delivery?
        onPause = { [weak self, weak vm] in
            guard let self, let vm, answered == nil else { return }
            answered = await vm.asks.answer(ask)
            XCTAssertEqual(typed.count, 1, "nothing of the answer yet")
        }

        let sent = await vm.lineDelivery.send(Self.otherLine, key: .input("action-1"), sessionID: s.id) { _ in }

        XCTAssertEqual(sent, .submitted)
        XCTAssertEqual(answered, .queued)
        await waitUntil { self.typed.count == 4 }
        guard typed.count == 4 else { return }
        XCTAssertTrue(typedText[0].contains(Self.otherLine))
        XCTAssertFalse(typedText[0].contains("Ask #"), "the lines never share a paste")
        XCTAssertEqual(typed[1], [0x0D])
        XCTAssertTrue(typedText[2].contains("Ask #\(askID) "))
        XCTAssertFalse(typedText[2].contains(Self.otherLine))
        XCTAssertEqual(typed[3], [0x0D])
        await waitUntil { vm.asks.answerNotices[askID] == .delivered(.submitted) }
    }

    /// The other way round: a line sent during an answer's pause is queued
    /// behind it and goes next, its own event saying where it went.
    func testAnotherLineDuringAnAnswersPauseGoesAfterIt() async throws {
        let (p, s, askID) = try await seed()
        let vm = makeVM()
        let ask = try await answerableAsk(vm, project: p, id: askID)
        var queued: SessionLineDelivery.Delivery?
        var events: [SessionLineDelivery.HeldEvent] = []
        onPause = { [weak vm] in
            guard let vm, queued == nil else { return }
            queued = await vm.lineDelivery.send(Self.otherLine, key: .input("action-2"), sessionID: s.id) {
                events.append($0)
            }
        }

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .submitted)
        XCTAssertEqual(queued, .queued)
        await waitUntil { events == [.tried(.submitted)] }
        XCTAssertEqual(typed.count, 4)
        guard typed.count == 4 else { return }
        XCTAssertTrue(typedText[0].contains("Ask #\(askID) "))
        XCTAssertEqual(typed[1], [0x0D])
        XCTAssertTrue(typedText[2].contains(Self.otherLine))
        XCTAssertEqual(typed[3], [0x0D])
    }

    /// A line held because the read before the paste failed goes on the
    /// next read of the states that succeeds (the app's wiring:
    /// `SessionAgentStateCenter.onRead`) — never on a timer.
    func testAHeldLineGoesOnTheNextSuccessfulReadNeverOnATimer() async throws {
        let (_, s, _) = try await seed()
        let gate = ReadGate()
        let agentStates = SessionAgentStateCenter(
            dbPool: pool, terminalCenter: center, interval: .seconds(3600), notifier: RecordingSessionNotifier(),
            defaults: defaults, notificationCenter: NotificationCenter(), read: { _ in try gate.check(); return [] }
        )
        let vm = makeVM(agentStates: agentStates)
        var events: [SessionLineDelivery.HeldEvent] = []

        let delivery = await vm.lineDelivery.send(Self.otherLine, key: .input("action-3"), sessionID: s.id) {
            events.append($0)
        }

        XCTAssertEqual(delivery, .held)
        XCTAssertEqual(vm.lineDelivery.heldKeys(sessionID: s.id), [.input("action-3")])
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(typed.isEmpty, "no timer sends it")
        XCTAssertTrue(events.isEmpty)
        let failed = await agentStates.poll()
        XCTAssertFalse(failed)
        XCTAssertTrue(typed.isEmpty, "a failed read sends nothing")

        gate.fails = false
        let read = await agentStates.poll()

        XCTAssertTrue(read)
        // No hook state this run: pasted, the owner presses Return.
        await waitUntil { events == [.tried(.typed)] }
        XCTAssertEqual(typed.count, 1)
        XCTAssertTrue(typedText.first?.contains(Self.otherLine) == true)
        XCTAssertFalse(typed.contains([0x0D]))
        XCTAssertTrue(vm.lineDelivery.heldKeys(sessionID: s.id).isEmpty)
    }

    /// A line held for a session that started a new run meanwhile goes
    /// nowhere: that run's brief has the context, not the old prompt.
    func testALineHeldForASessionThatStartedANewRunGoesNowhere() async throws {
        let (_, s, _) = try await seed()
        let vm = makeVM()
        var approval = true
        vm.lineDelivery.needsApproval = { _ in approval }
        var events: [SessionLineDelivery.HeldEvent] = []
        let delivery = await vm.lineDelivery.send(Self.otherLine, key: .input("action-4"), sessionID: s.id) {
            events.append($0)
        }
        XCTAssertEqual(delivery, .held)

        processes[0].onExit?(0)
        // The same process object: only the run number tells it apart.
        center.start(s, fresh: false)
        XCTAssertEqual(center.states[s.id], .running)
        approval = false
        await vm.lineDelivery.deliverHeld()

        XCTAssertEqual(events, [.tried(.noSession)])
        XCTAssertTrue(typed.isEmpty)
        XCTAssertTrue(vm.lineDelivery.heldKeys(sessionID: s.id).isEmpty)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met in \(timeout)s")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

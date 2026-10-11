import AppKit
import Darwin
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Answers `workbench escalate-question` calls from a script, optionally
/// holding each call open until the test releases it. No process is spawned.
private final class ScriptedEscalationRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private var gates: [AsyncGate] = []
    private var holding = false
    private var answers: [String]

    /// Each call takes the next answer; the last one repeats.
    init(_ answers: String...) {
        self.answers = answers
    }

    var invocations: [[String]] { lock.withLock { calls } }
    var reasons: [String] { invocations.map { $0.last ?? "" } }

    func hold() { lock.withLock { holding = true } }

    func release(_ index: Int) { lock.withLock { gates[index] }.release() }

    func run(args: [String]) async throws -> Data {
        let gate = AsyncGate()
        let (held, answer) = lock.withLock {
            calls.append(args)
            gates.append(gate)
            let answer = answers.count > 1 ? answers.removeFirst() : answers[0]
            return (holding, answer)
        }
        if held { await gate.wait() }
        return Data(answer.utf8)
    }
}

private enum Answer {
    static let filed = #"{"ok":true,"outcome":"filed","ask_id":31,"level":"quick"}"#
    static let gone = #"{"ok":true,"outcome":"gone"}"#
    static func error(_ code: String) -> String { #"{"ok":false,"error_code":"\#(code)","error":"why"}"# }
}

/// Timers a test fires by hand.
@MainActor
private final class ManualTimers {
    private var timers: [(id: Int, seconds: TimeInterval, fire: @MainActor () -> Void)] = []
    private var nextID = 0

    var pending: [TimeInterval] { timers.map(\.seconds) }

    func schedule(_ seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        timers.append((id, seconds, fire))
        return { [weak self] in self?.timers.removeAll { $0.id == id } }
    }

    func fireAll() {
        let due = timers
        timers = []
        due.forEach { $0.fire() }
    }
}

/// The runner of spec 2026-10-10-owner-asks-v2 Part 5.2 over
/// `ChatQuestionEscalationPolicy`.
@MainActor
final class ChatQuestionEscalatorTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 1_790_000_000)
    /// When the guard recorded the question: a minute into the run.
    private var asked: Date { started.addingTimeInterval(60) }
    private var now = Date()
    private var rows: [SessionAgentStateRow] = []
    private var live: Set<Int64> = [1]
    private var presence: ChatQuestionEscalationPolicy.Presence? = .present
    private var drafts: Set<Int64> = []
    private var filed: [Int64] = []
    private var logs: [String] = []
    private var timers: ManualTimers!
    private var escalators: [ChatQuestionEscalator] = []
    private var presenceCenters: [OwnerPresenceCenter] = []
    /// A stub process a reaping test started: killed if still there.
    private var stubPID: pid_t?

    override func setUp() async throws {
        now = asked
        rows = [row()]
        live = [1, 2]
        presence = .present
        drafts = []
        filed = []
        logs = []
        timers = ManualTimers()
        escalators = []
        presenceCenters = []
        stubPID = nil
    }

    override func tearDown() async throws {
        // No run outlives its test.
        escalators.forEach { $0.stop() }
        presenceCenters.forEach { $0.stop() }
        if let stubPID, kill(stubPID, 0) == 0 { kill(stubPID, SIGKILL) }
    }

    private func stamp(_ date: Date) -> String { SessionAgentStatus.formatStamp(date) }

    private func row(_ id: Int64 = 1, at questionAt: Date? = nil, state: String = "waiting") -> SessionAgentStateRow {
        let at = questionAt ?? asked
        var row = SessionAgentStateRow(id: id, projectID: 7, title: "s", agentState: state,
                                       agentStateAt: stamp(at), workbenchName: "acme")
        row.chatQuestion = #"{"question":"Red or orange?","options":[]}"#
        row.chatQuestionAt = stamp(at)
        return row
    }

    private func makeEscalator(_ runner: any CLIRunnerProtocol) -> ChatQuestionEscalator {
        let escalator = bareEscalator(runner)
        escalator.presence = { [weak self] _ in self?.presence }
        escalator.hasOwnerDraft = { [weak self] in self?.drafts.contains($0) ?? false }
        escalator.onFiled = { [weak self] in self?.filed.append($0) }
        escalator.log = { [weak self] in self?.logs.append($0) }
        escalator.start()
        return escalator
    }

    /// An escalator on the test's clock, timers and rows; nothing else wired.
    private func bareEscalator(_ runner: any CLIRunnerProtocol) -> ChatQuestionEscalator {
        let timers: ManualTimers = timers
        let escalator = ChatQuestionEscalator(
            runner: runner, clock: { [weak self] in self?.now ?? .distantPast }, schedule: { timers.schedule($0, $1) }
        )
        escalator.sessions = { [weak self] in
            guard let self else { return .empty }
            return .init(rows: rows, liveIDs: live, startedAt: [1: started, 2: started])
        }
        escalators.append(escalator)
        return escalator
    }

    /// Moves the clock to `seconds` after the question and evaluates.
    private func evaluate(_ escalator: ChatQuestionEscalator, after seconds: TimeInterval) async {
        now = asked.addingTimeInterval(seconds)
        escalator.evaluate()
        await settled(escalator)
    }

    private func eventually(_ what: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline { return XCTFail("timed out: \(what)") }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func settled(_ escalator: ChatQuestionEscalator) async {
        await eventually("the runs settle") { !escalator.isEscalating(1) && !escalator.isEscalating(2) }
    }

    // MARK: - Settling and triggers

    /// E22a: nothing before presence settles — then nothing for a session
    /// that is not live, and a live one escalates.
    func testNothingBeforePresenceSettles() async {
        let runner = ScriptedEscalationRunner(Answer.gone)
        presence = nil
        let escalator = makeEscalator(runner)
        await evaluate(escalator, after: 3600)
        XCTAssertEqual(runner.invocations, [])

        presence = .present
        live = []
        await evaluate(escalator, after: 3600)
        XCTAssertEqual(runner.invocations, [], "not live")

        live = [1]
        await evaluate(escalator, after: 3600)
        XCTAssertEqual(runner.invocations, [[
            "workbench", "escalate-question", "--workbench", "7", "--session", "1",
            "--at", stamp(asked), "--reason", "timeout"
        ]])
    }

    /// The presence center's changes evaluate, with no call from the agent
    /// states: once the owner leaves the app, a
    /// question recorded in a session not entered since the center started
    /// escalates as `away` at once.
    func testPresenceChangeTriggersAnEvaluation() async {
        let runner = ScriptedEscalationRunner(Answer.gone)
        rows = []
        now = asked.addingTimeInterval(-30)
        let escalator = bareEscalator(runner)
        let notifications = NotificationCenter()
        let timers: ManualTimers = timers
        let center = OwnerPresenceCenter(
            writer: { _, _ in }, clock: { [weak self] in self?.now ?? .distantPast }, schedule: { timers.schedule($0, $1) },
            sources: .init(app: notifications, workspace: notifications, distributed: notifications)
        )
        presenceCenters.append(center)
        center.screen = { .init(keyWindowShows: .workbenchSession, selectedSession: 2) }
        center.isAppActive = { true }
        center.isScreenLocked = { false }
        escalator.follow(presence: center)
        escalator.start()
        center.start()
        await center.flushWrites()

        rows = [row()]
        now = asked.addingTimeInterval(5)
        await settled(escalator)
        XCTAssertEqual(runner.invocations, [], "nothing evaluated since the question appeared")

        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        timers.fireAll() // the 2 s flicker debounce: the loss is written
        await eventually("the presence change evaluates") { runner.invocations.count == 1 }
        XCTAssertEqual(runner.reasons, ["away"])
        await settled(escalator)
        await center.flushWrites()
    }

    func testTheTickRunsOnlyWhileAQuestionIsHeld() async {
        let runner = ScriptedEscalationRunner(Answer.error("busy"))
        let escalator = makeEscalator(runner)
        XCTAssertEqual(timers.pending, [ChatQuestionEscalator.tickInterval])
        now = asked.addingTimeInterval(600)
        timers.fireAll()
        await settled(escalator)
        XCTAssertEqual(runner.invocations.count, 1, "the tick evaluated")
        XCTAssertEqual(timers.pending, [ChatQuestionEscalator.tickInterval], "re-armed")

        rows = []
        escalator.evaluate()
        XCTAssertEqual(timers.pending, [], "no question, no tick")
    }

    // MARK: - Runs

    func testOneRunInFlightPerSession() async {
        let runner = ScriptedEscalationRunner(Answer.gone)
        runner.hold()
        let escalator = makeEscalator(runner)
        now = asked.addingTimeInterval(600)
        escalator.evaluate()
        await eventually("the run starts") { runner.invocations.count == 1 }
        now = asked.addingTimeInterval(3600)
        escalator.evaluate()
        escalator.evaluate()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertTrue(escalator.isEscalating(1))
        runner.release(0)
        await settled(escalator)
    }

    /// The in-flight rule is per session: session 1's run does not hold
    /// session 2's back.
    func testARunInFlightDoesNotBlockAnotherSession() async {
        let runner = ScriptedEscalationRunner(Answer.gone)
        runner.hold()
        rows = [row(1), row(2)]
        let escalator = makeEscalator(runner)
        now = asked.addingTimeInterval(600)
        escalator.evaluate()
        await eventually("both sessions run") { runner.invocations.count == 2 }
        XCTAssertEqual(runner.invocations.map { $0[5] }, ["1", "2"])
        runner.release(0)
        runner.release(1)
        await settled(escalator)
    }

    /// The stop rule is per session too: session 1's `gone` leaves session
    /// 2's question to escalate.
    func testAStoppedSessionDoesNotStopAnother() async {
        let runner = ScriptedEscalationRunner(Answer.gone)
        let escalator = makeEscalator(runner)
        await evaluate(escalator, after: 600)
        XCTAssertEqual(runner.invocations.count, 1)
        rows = [row(1), row(2)]
        await evaluate(escalator, after: 700)
        XCTAssertEqual(runner.invocations.map { $0[5] }, ["1", "2"])
    }

    /// E20: `busy` and `open_cap` keep the question; tried again at most
    /// once a minute, logged once.
    func testATransientFailureIsRetriedAtMostOncePerMinute() async {
        let runner = ScriptedEscalationRunner(Answer.error("busy"), Answer.error("open_cap"), Answer.filed)
        let escalator = makeEscalator(runner)
        await evaluate(escalator, after: 600)
        await evaluate(escalator, after: 659)
        XCTAssertEqual(runner.invocations.count, 1, "no retry within the minute")
        await evaluate(escalator, after: 660)
        XCTAssertEqual(runner.invocations.count, 2)
        await evaluate(escalator, after: 719)
        XCTAssertEqual(runner.invocations.count, 2)
        await evaluate(escalator, after: 720)
        XCTAssertEqual(runner.invocations.count, 3)
        XCTAssertEqual(filed, [7])
        XCTAssertEqual(logs.filter { $0.contains("retrying") }.count, 1, "logged once per question")
    }

    /// E20a: any other code stops the runs for that question; a new
    /// `chat_question_at` starts fresh.
    func testANonTransientFailureStopsRetrying() async throws {
        for code in ["not_found", "bad_args", "schema", "internal", "unheard_of"] {
            try await setUp()
            let runner = ScriptedEscalationRunner(Answer.error(code))
            let escalator = makeEscalator(runner)
            await evaluate(escalator, after: 600)
            await evaluate(escalator, after: 700)
            await evaluate(escalator, after: 3600)
            XCTAssertEqual(runner.invocations.count, 1, code)
            XCTAssertEqual(logs.filter { $0.contains("not retried") }.count, 1, code)

            let newer = asked.addingTimeInterval(3000)
            rows = [row(at: newer)]
            now = newer.addingTimeInterval(600)
            escalator.evaluate()
            await settled(escalator)
            XCTAssertEqual(runner.invocations.count, 2, "\(code): a new question starts fresh")
            XCTAssertEqual(runner.invocations.last?[7], stamp(newer))
            escalator.stop()
        }
    }

    /// A run that printed nothing readable is the Desktop's own failure:
    /// not retried.
    func testUnreadableOutputStopsRetrying() async {
        let runner = ScriptedEscalationRunner("Error: unknown command \"escalate-question\"")
        let escalator = makeEscalator(runner)
        await evaluate(escalator, after: 600)
        await evaluate(escalator, after: 900)
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(logs.count, 1)
    }

    func testGoneOutcomeStopsRetrying() async {
        let runner = ScriptedEscalationRunner(Answer.gone)
        let escalator = makeEscalator(runner)
        await evaluate(escalator, after: 600)
        await evaluate(escalator, after: 700)
        await evaluate(escalator, after: 3600)
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(filed, [])
        XCTAssertEqual(logs, [])
    }

    /// The Quick ask shows at once; the stale row read before Go's clear
    /// lands raises nothing again.
    func testFiledOutcomeAsksTheAsksPollForARead() async {
        let runner = ScriptedEscalationRunner(Answer.filed)
        let escalator = makeEscalator(runner)
        await evaluate(escalator, after: 600)
        XCTAssertEqual(filed, [7])
        await evaluate(escalator, after: 3600)
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(filed, [7])
    }

    /// Go clears the question in the filing transaction: a read landing
    /// while the run is in flight drops the bookkeeping, and the filed ask
    /// is still announced.
    func testFiledIsAnnouncedAfterAReadDroppedTheQuestion() async {
        let runner = ScriptedEscalationRunner(Answer.filed)
        runner.hold()
        let escalator = makeEscalator(runner)
        now = asked.addingTimeInterval(600)
        escalator.evaluate()
        await eventually("the run starts") { runner.invocations.count == 1 }
        var cleared = row()
        cleared.chatQuestion = nil
        cleared.chatQuestionAt = nil
        rows = [cleared]
        escalator.evaluate()
        runner.release(0)
        await settled(escalator)
        XCTAssertEqual(filed, [7])
        XCTAssertEqual(logs.filter { $0.contains("raised as ask #31") }.count, 1)
    }

    /// The policy's `unreadableStamp` raises nothing and is logged once
    /// per question, though `decide` returns it on every tick.
    func testAnUnreadableStampIsLoggedOnce() async {
        let runner = ScriptedEscalationRunner(Answer.gone)
        var future = row()
        future.chatQuestionAt = "not a stamp"
        rows = [future]
        let escalator = makeEscalator(runner)
        await evaluate(escalator, after: 600)
        await evaluate(escalator, after: 900)
        XCTAssertEqual(runner.invocations, [])
        XCTAssertEqual(logs.count, 1)

        future.chatQuestionAt = "still not a stamp"
        rows = [future]
        await evaluate(escalator, after: 1000)
        XCTAssertEqual(logs.count, 2, "another question, another line")
    }

    func testADraftDefersTheRun() async {
        let runner = ScriptedEscalationRunner(Answer.gone)
        drafts = [1]
        let escalator = makeEscalator(runner)
        await evaluate(escalator, after: 1799)
        XCTAssertEqual(runner.invocations, [])
        await evaluate(escalator, after: 1800)
        XCTAssertEqual(runner.reasons, ["timeout"])
    }

    // MARK: - Stop

    /// A real child: `stop()` terminates it and the runner waits for it, so
    /// its pid is gone (reaped, not a zombie); nothing is applied.
    func testStopCancelsAndReapsTheRun() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("escalator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("pid")
        let stub = dir.appendingPathComponent("watchtower")
        try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec sleep 30\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let escalator = makeEscalator(ProcessCLIRunner(binaryPath: stub.path))
        now = asked.addingTimeInterval(600)
        escalator.evaluate()
        await eventually("the stub starts") {
            (try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let pid = try XCTUnwrap(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        stubPID = pid
        XCTAssertTrue(escalator.isEscalating(1))

        escalator.stop()
        XCTAssertFalse(escalator.isEscalating(1))
        await eventually("the child is reaped") { kill(pid, 0) == -1 && errno == ESRCH }
        XCTAssertEqual(filed, [])
        XCTAssertEqual(logs, [], "a cancelled run applies nothing")
    }
}

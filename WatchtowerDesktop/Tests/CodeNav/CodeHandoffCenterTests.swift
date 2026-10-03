import XCTest
import AppKit
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The stored agent state per session id ("working", "waiting", "approval").
private final class AgentStates: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Int64: String] = [:]

    func storeAgentState(_ id: Int64, _ state: String) { lock.withLock { states[id] = state } }

    func agentStateRows(_ asked: [Int64]) -> [SessionAgentStateRow] {
        lock.withLock {
            asked.compactMap { id in
                states[id].map {
                    SessionAgentStateRow(id: id, projectID: nil, title: "s", agentState: $0,
                                         agentStateAt: "2999-01-01T00:00:00.000Z", workbenchName: nil)
                }
            }
        }
    }
}

/// Hand to Claude Code (spec 2026-10-02 §9.5): the sheet's Send types the
/// stored conversation into a running session and submits it, or starts a
/// new session with it; the session opens beside the editor.
@MainActor
final class CodeHandoffCenterTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var processes: [FakeTerminalSession] = []
    private var terminals: TerminalCenter!
    private var stored = AgentStates()
    /// Runs inside the paste→Return pause.
    private var duringPause: (@MainActor () async -> Void)?
    private var agentStates: SessionAgentStateCenter!
    private var beeps = 0

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "CodeHandoffCenterTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt handoff \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        processes = []
        beeps = 0
        stored = AgentStates()
        duringPause = nil
        terminals = TerminalCenter(
            makeProcess: { [weak self] in
                let process = FakeTerminalSession(pid: 0)
                self?.processes.append(process)
                return process
            },
            signaller: ProcessGroupSignaller(
                signal: { _, _ in },
                isAlive: { _ in false },
                sleep: { [weak self] _ in await self?.duringPause?() }
            )
        )
        terminals.shell = { "/bin/zsh" }
        terminals.transcriptExists = { _ in false }
        let stored = stored
        agentStates = SessionAgentStateCenter(
            dbPool: pool, terminalCenter: terminals, notifier: RecordingSessionNotifier(), defaults: defaults
        ) { stored.agentStateRows($0) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeHandoffFixture() async throws -> (CodeHandoffCenter, WorkbenchesViewModel, Workbench) {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: terminals, agentStates: agentStates)
        vm.titleService = { _ in .init(title: "", written: false) }
        let dir = folder.appendingPathComponent("acme").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let project = try await pool.write { db -> Workbench in
            let id = try TestDatabase.insertWorkbench(db, name: "acme", folder: dir)
            return try XCTUnwrap(try WorkbenchQueries.fetch(db, id: id))
        }
        await vm.reload()
        let handoff = CodeHandoffCenter { [weak self] in self?.beeps += 1 }
        handoff.workbenches = vm
        handoff.terminalCenter = terminals
        handoff.dbPool = pool
        return (handoff, vm, project)
    }

    /// A code question with one answer, and one reply still streaming.
    private func storedQuestion(_ project: Workbench) throws -> CodeQuestionRef {
        let origin = CodeQuestionOrigin(path: "Sources/App.swift", line: 12, selection: nil)
        let id = try CodeQuestionSurface.createConversation(
            workbenchID: project.id, origin: origin, choice: .init(provider: .claude, model: ""), dbPool: pool)
        let now = Date().timeIntervalSince1970
        try pool.write { db in
            let first = try ChatMessageQueries.beginEmbeddedTurn(db, conversationID: id, ownerText: "Why save twice?",
                                                                 turnID: "t1", provider: "claude", now: now)
            try ChatMessageQueries.finalizeEmbedded(db, messageID: first.assistantID, text: "See Sources/Store.swift:40.",
                                                    status: "complete", errorCode: nil, errorMessage: nil)
            _ = try ChatMessageQueries.beginEmbeddedTurn(db, conversationID: id, ownerText: "And then?", turnID: "t2",
                                                         provider: "claude", now: now + 1)
        }
        return CodeQuestionRef(project: project, conversationID: id, origin: origin)
    }

    /// The Files pane alone on the page.
    private var filesAlone: WorkspaceLayout {
        var layout = WorkspaceLayout.default
        layout.primary = .files
        return layout
    }

    private func runningSession(_ vm: WorkbenchesViewModel, _ project: Workbench) async throws -> TerminalSession {
        await vm.newSession(projectID: project.id)
        return try XCTUnwrap(vm.terminalSessions[project.id]?.first)
    }

    func testTheRequestIsBuiltFromTheStoredMessagesLeavingTheStreamingReplyOut() async throws {
        let (handoff, _, project) = try await makeHandoffFixture()
        await handoff.handConversation(try storedQuestion(project))
        let text = try XCTUnwrap(handoff.requests[project.id]?.text)
        XCTAssertTrue(text.hasPrefix(HandoffText.header + "\nAsked at Sources/App.swift:12"))
        XCTAssertTrue(text.contains("Question: Why save twice?\n\nAnswer:\nSee Sources/Store.swift:40."))
        XCTAssertTrue(text.hasSuffix("Question: And then?\n\nReferences: Sources/App.swift:12, Sources/Store.swift:40"),
                      text)
    }

    private func bracketedPasteBytes(_ text: String) -> [UInt8] {
        [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] + Array(text.utf8) + [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
    }

    /// A session waiting for the owner at its prompt: pasted once, then
    /// Return; the sheet closes and the session opens beside the editor.
    func testARunningSessionGetsThePasteThenReturnAndOpensBesideTheEditor() async throws {
        let (handoff, vm, project) = try await makeHandoffFixture()
        let session = try await runningSession(vm, project)
        stored.storeAgentState(session.id, "waiting")
        await agentStates.poll()
        vm.setLayout(filesAlone, projectID: project.id)
        await handoff.handConversation(try storedQuestion(project))
        let text = try XCTUnwrap(handoff.requests[project.id]?.text)
        XCTAssertEqual(handoff.defaultTarget(workbenchID: project.id), .session(session.id))

        let sent = await handoff.send(to: .session(session.id), workbenchID: project.id)

        XCTAssertTrue(sent)
        XCTAssertNil(handoff.requests[project.id], "the sheet closes")
        XCTAssertEqual(processes[0].inputs, [bracketedPasteBytes(text), [0x0D]], "one paste, then one Return")
        var expected = filesAlone
        expected.openBeside(.session(session.id), keeping: .files)
        XCTAssertEqual(vm.layout(projectID: project.id), expected)
        XCTAssertEqual(vm.layout(projectID: project.id).visiblePanes, [.files, .session(session.id)], "beside the editor")
    }

    /// Ruling R52: a working session (or one with no reported state) gets
    /// the paste and no Return; the pane says to press Return.
    func testAWorkingSessionGetsThePasteButNoReturn() async throws {
        let (handoff, vm, project) = try await makeHandoffFixture()
        let session = try await runningSession(vm, project)
        stored.storeAgentState(session.id, "working")
        await agentStates.poll()
        handoff.handQuery("why", project: project, origin: CodeQuestionOrigin(path: "", line: 0, selection: nil))
        let text = try XCTUnwrap(handoff.requests[project.id]?.text)

        let sent = await handoff.send(to: .session(session.id), workbenchID: project.id)

        XCTAssertTrue(sent)
        XCTAssertEqual(processes[0].inputs, [bracketedPasteBytes(text)], "no 0x0D into a working session")
        XCTAssertTrue(terminals.pasteHints.contains(session.id))
        XCTAssertNil(handoff.requests[project.id])
    }

    /// Ruling R52: a permission prompt that appears during the pause stops
    /// the Return.
    func testAStateThatTurnsToApprovalDuringThePauseGetsNoReturn() async throws {
        let (handoff, vm, project) = try await makeHandoffFixture()
        let session = try await runningSession(vm, project)
        stored.storeAgentState(session.id, "waiting")
        await agentStates.poll()
        handoff.handQuery("why", project: project, origin: CodeQuestionOrigin(path: "", line: 0, selection: nil))
        let text = try XCTUnwrap(handoff.requests[project.id]?.text)
        duringPause = { [self] in
            stored.storeAgentState(session.id, "approval")
            await agentStates.poll()
        }

        await handoff.send(to: .session(session.id), workbenchID: project.id)

        XCTAssertEqual(processes[0].inputs, [bracketedPasteBytes(text)], "no 0x0D once it asks for approval")
        XCTAssertTrue(terminals.pasteHints.contains(session.id))
    }

    /// The state is polled again after the pause: a permission prompt the
    /// hook stored during it stops the Return although no 1 s poll ran.
    func testTheStateIsRefreshedAfterThePause() async throws {
        let (handoff, vm, project) = try await makeHandoffFixture()
        let session = try await runningSession(vm, project)
        stored.storeAgentState(session.id, "waiting")
        await agentStates.poll()
        handoff.handQuery("why", project: project, origin: CodeQuestionOrigin(path: "", line: 0, selection: nil))
        let text = try XCTUnwrap(handoff.requests[project.id]?.text)
        duringPause = { [self] in stored.storeAgentState(session.id, "approval") }

        await handoff.send(to: .session(session.id), workbenchID: project.id)

        XCTAssertEqual(processes[0].inputs, [bracketedPasteBytes(text)], "the refreshed state stops the Return")
        XCTAssertEqual(vm.sessionState(session), .needsApproval)
    }

    /// Ruling R54(d): Cancel during the pause stops the queued Return and
    /// opens nothing.
    func testCancelDuringThePauseStopsTheReturn() async throws {
        let (handoff, vm, project) = try await makeHandoffFixture()
        let session = try await runningSession(vm, project)
        stored.storeAgentState(session.id, "waiting")
        await agentStates.poll()
        vm.setLayout(filesAlone, projectID: project.id)
        handoff.handQuery("why", project: project, origin: CodeQuestionOrigin(path: "", line: 0, selection: nil))
        let text = try XCTUnwrap(handoff.requests[project.id]?.text)
        duringPause = { handoff.cancel(workbenchID: project.id) }

        let sent = await handoff.send(to: .session(session.id), workbenchID: project.id)

        XCTAssertFalse(sent)
        XCTAssertEqual(processes[0].inputs, [bracketedPasteBytes(text)], "no 0x0D after Cancel")
        XCTAssertEqual(vm.layout(projectID: project.id), filesAlone, "the session is not opened")
    }

    /// New session: started with the text as its first prompt, never on
    /// the shell command line, beside the editor.
    func testANewSessionStartsWithTheTextAsItsFirstPrompt() async throws {
        let (handoff, vm, project) = try await makeHandoffFixture()
        vm.setLayout(filesAlone, projectID: project.id)
        handoff.handQuery("why save", project: project, origin: CodeQuestionOrigin(path: "src/save.swift", line: 7, selection: nil))
        let text = try XCTUnwrap(handoff.requests[project.id]?.text)
        XCTAssertEqual(handoff.defaultTarget(workbenchID: project.id), .newSession, "no session runs")

        let sent = await handoff.send(to: .newSession, workbenchID: project.id)

        XCTAssertTrue(sent)
        let launch = try XCTUnwrap(processes.first?.launches.first)
        XCTAssertEqual(launch.environment.last, "\(TerminalLaunch.firstPromptEnv)=\(text)")
        XCTAssertFalse(launch.args.joined().contains("why save"))
        let row = try XCTUnwrap(vm.terminalSessions[project.id]?.first)
        var expected = filesAlone
        expected.openBeside(.session(row.id), keeping: .files)
        XCTAssertEqual(vm.layout(projectID: project.id), expected)
        XCTAssertEqual(vm.layout(projectID: project.id).visiblePanes, [.files, .session(row.id)], "beside the editor")
        XCTAssertTrue(processes[0].inputs.isEmpty, "nothing is typed into a new session")
    }

    /// A session waiting on a permission prompt is never sent a Return —
    /// it would answer the prompt.
    func testASessionWaitingForApprovalIsRefused() async throws {
        let (handoff, vm, project) = try await makeHandoffFixture()
        let session = try await runningSession(vm, project)
        stored.storeAgentState(session.id, "approval")
        await agentStates.poll()
        handoff.handQuery("why", project: project, origin: CodeQuestionOrigin(path: "", line: 0, selection: nil))
        XCTAssertEqual(handoff.choices(workbenchID: project.id).map(\.isWaitingForApproval), [true])
        XCTAssertEqual(handoff.defaultTarget(workbenchID: project.id), .newSession)

        let sent = await handoff.send(to: .session(session.id), workbenchID: project.id)

        XCTAssertFalse(sent)
        XCTAssertTrue(processes[0].inputs.isEmpty)
        XCTAssertNotNil(handoff.requests[project.id], "the sheet stays")
        XCTAssertEqual(handoff.errors[project.id],
                       "That session is waiting for a permission answer. Answer it in the terminal first.")
    }

    func testASessionThatEndedKeepsTheSheetWithAnError() async throws {
        let (handoff, vm, project) = try await makeHandoffFixture()
        let session = try await runningSession(vm, project)
        handoff.handQuery("why", project: project, origin: CodeQuestionOrigin(path: "", line: 0, selection: nil))
        processes[0].exit(0)

        let sent = await handoff.send(to: .session(session.id), workbenchID: project.id)

        XCTAssertFalse(sent)
        XCTAssertTrue(processes[0].inputs.isEmpty)
        XCTAssertEqual(handoff.errors[project.id], "That session is no longer running. Pick another or start a new one.")
    }

    func testNothingToHandBeepsAndOpensNoSheet() async throws {
        let (handoff, _, project) = try await makeHandoffFixture()
        let empty = try CodeQuestionSurface.createConversation(
            workbenchID: project.id, origin: CodeQuestionOrigin(path: "a.go", line: 1, selection: nil),
            choice: .init(provider: .claude, model: ""), dbPool: pool)
        await handoff.handConversation(CodeQuestionRef(
            project: project, conversationID: empty, origin: CodeQuestionOrigin(path: "a.go", line: 1, selection: nil)))
        handoff.handQuery("   ", project: project, origin: CodeQuestionOrigin(path: "", line: 0, selection: nil))
        XCTAssertNil(handoff.requests[project.id])
        XCTAssertEqual(beeps, 2)
    }

    func testCancelClosesTheSheet() async throws {
        let (handoff, _, project) = try await makeHandoffFixture()
        handoff.handQuery("why", project: project, origin: CodeQuestionOrigin(path: "", line: 0, selection: nil))
        handoff.cancel(workbenchID: project.id)
        XCTAssertNil(handoff.requests[project.id])
        let sent = await handoff.send(to: .newSession, workbenchID: project.id)
        XCTAssertFalse(sent)
        XCTAssertTrue(processes.isEmpty)
    }
}

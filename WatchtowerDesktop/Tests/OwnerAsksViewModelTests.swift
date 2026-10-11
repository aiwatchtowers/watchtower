import XCTest
import AppKit
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// A process that runs a probe on every input, so a test can see what the
/// DB held at the moment the line was typed.
@MainActor
private final class ProbedInputSession: TerminalSessionProcess {
    let view = NSView()
    let pid: pid_t = 0
    var onExit: ((Int32?) -> Void)?
    var onOwnerInput: (([UInt8]) -> Void)?
    var bracketedPasteMode = true
    private(set) var inputs: [[UInt8]] = []
    var onInput: (() -> Void)?

    func start(_ launch: TerminalLaunch) {}
    func detach() {}
    func sendInput(_ bytes: [UInt8]) {
        onInput?()
        inputs.append(bytes)
    }
}

@MainActor
final class OwnerAsksViewModelTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var processes: [ProbedInputSession] = []
    private var center: TerminalCenter!
    private var copied: [String] = []
    /// Runs in the pause between an answer's paste and its Return.
    private var onPause: (() async -> Void)?

    nonisolated private static let questions = #"{"questions":[{"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}]}"#

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "OwnerAsksViewModelTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt asks \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        processes = []
        copied = []
        onPause = nil
        center = TerminalCenter(
            makeProcess: { [weak self] in
                let process = ProbedInputSession()
                self?.processes.append(process)
                return process
            },
            signaller: ProcessGroupSignaller(
                signal: { _, _ in }, isAlive: { _ in false },
                sleep: { [weak self] _ in await self?.onPause?() }
            )
        )
        center.shell = { "/bin/zsh" }
        center.copyToClipboard = { [weak self] in self?.copied.append($0) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    /// Its sessions' hooks count as having reported this run and every
    /// state read as fresh (no `SessionAgentStateCenter` here), so an
    /// answer may be submitted. The held hint's wait never ends by itself.
    private func makeVM() -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults, terminalCenter: center)
        vm.asks.hasHookState = { _ in true }
        vm.asks.refreshStates = { true }
        vm.asks.holdSleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
        return vm
    }

    /// A workbench with one shell session row, and an open question ask
    /// filed from it (`session: false` = filed outside the app).
    private func seed(session: Bool = true) async throws -> (project: Int64, session: TerminalSession, ask: Int64) {
        let acme = folder.path
        return try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, folder: acme)
            let s = try TerminalSessionQueries.create(d, .init(projectID: p, kind: .shell, title: "zsh", folderPath: acme))
            let ask = try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: session ? s.id : nil, payload: Self.questions)
            return (p, s, ask)
        }
    }

    private func openAsk(_ vm: WorkbenchesViewModel, project: Int64, id: Int64) async throws -> OwnerAsk {
        await vm.asks.load(projectID: project)
        return try XCTUnwrap(vm.asks.openAsks[project]?.first { $0.id == id })
    }

    private func status(_ id: Int64) async throws -> (status: String, answer: String, answeredAt: String) {
        try await pool.read { d in
            let row = try XCTUnwrap(Row.fetchOne(d, sql: "SELECT status, answer, answered_at FROM owner_asks WHERE id = ?", arguments: [id]))
            return (row["status"], row["answer"], row["answered_at"])
        }
    }

    private func pick(_ vm: WorkbenchesViewModel, _ askID: Int64) {
        vm.asks.drafts.update(askID) { $0.picks["a"] = .init(labels: ["Yes"]) }
    }

    private var typed: [[UInt8]] { processes.flatMap(\.inputs) }

    // MARK: - Navigation

    /// House rule: the drafts live on the AppState-owned VM, so leaving the
    /// tab and switching workbenches keeps them.
    func testDraftsSurviveNavigatingAwayAndBack() async throws {
        let (p, _, askID) = try await seed()
        let appState = AppState()
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.initWorkbenches(
            dbPool: pool, cliRunner: FakeCLIRunner(), notifier: RecordingWorkbenchNotifier(),
            sessionNotifier: RecordingSessionNotifier()
        )
        let vm = try XCTUnwrap(appState.workbenchesViewModel)
        appState.selectedDestination = .workbench
        vm.selectedWorkbenchID = p
        vm.asks.openDrawer(askID: askID, projectID: p)
        vm.asks.drafts.update(askID) {
            $0.picks["a"] = .init(labels: ["No"])
            $0.note = "Keep the flag off"
        }

        appState.selectedDestination = .inbox
        vm.selectedWorkbenchID = nil
        appState.selectedDestination = .workbench
        vm.selectedWorkbenchID = p

        XCTAssertTrue(appState.workbenchesViewModel === vm, "the same AppState-owned VM, not a fresh one")
        XCTAssertEqual(vm.asks.drafts.askDraft(for: askID).picks["a"], .init(labels: ["No"]))
        XCTAssertEqual(vm.asks.drafts.askDraft(for: askID).note, "Keep the flag off")
        XCTAssertEqual(vm.asks.drawerAskIDs[p], askID)
        vm.asks.stop()
    }

    // MARK: - Answering

    func testAnsweringARunningSessionWritesThenSubmitsTheLineOnceAndFocusesTheTerminal() async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        let vm = makeVM()
        vm.selectedWorkbenchID = p
        vm.layout.show(.board)
        let ask = try await openAsk(vm, project: p, id: askID)
        vm.asks.openDrawer(askID: askID, projectID: p)
        vm.asks.drawerExpanded = true
        pick(vm, askID)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .submitted)
        XCTAssertFalse(vm.asks.drawerExpanded, "closed through closeDrawer")
        let stored = try await status(askID)
        XCTAssertEqual(stored.status, "answered")
        XCTAssertEqual(try OwnerAskAnswer.decode(stored.answer).answers, [.init(id: "a", labels: ["Yes"])])
        XCTAssertNotNil(stored.answeredAt.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression),
                        "answered_at is UTC yyyy-MM-ddTHH:mm:ssZ, got \(stored.answeredAt)")
        let line = OwnerAskPrompt.line(id: askID, kind: .question, answer: try OwnerAskAnswer.decode(stored.answer))
        XCTAssertEqual(typed.count, 2, "exactly one paste, then its Return")
        XCTAssertTrue(String(bytes: typed[0], encoding: .utf8)?.contains(line) == true)
        XCTAssertEqual(typed[1], [0x0D])
        XCTAssertNil(vm.asks.drawerAskIDs[p], "the drawer closes: the terminal takes over")
        XCTAssertTrue(vm.layout(projectID: p).visiblePanes.contains(.session(s.id)), "the page shows the session")
        XCTAssertNotNil(center.keyboardFocusSerial(for: s.id), "the keyboard moves into it")
        XCTAssertTrue(vm.asks.drafts.askDraft(for: askID).isEmpty, "the answer is written; the draft goes")
        XCTAssertEqual(vm.asks.openAsks[p], [], "the answered ask leaves the open list")
        XCTAssertEqual(vm.asks.answerNotices[askID]?.text, OwnerAsksViewModel.answerSentNote)
        XCTAssertNil(center.answerHints[s.id], "nothing left for the owner to do")
    }

    /// PROJ-12 (spec 2026-10-03 Part 9, its "PROJ-11"; amended 2026-10-04,
    /// board #379): the answer is stored before anything is typed, the line
    /// is one bracketed paste with no line break or control character of its
    /// own, and Return follows as a write of its own.
    func testProj12_TheAnswerIsStoredBeforeTheLineIsTypedThenSubmitted() async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        var statusWhenTyped: String?
        processes[0].onInput = { [pool] in
            statusWhenTyped = try? pool?.read { try String.fetchOne($0, sql: "SELECT status FROM owner_asks WHERE id = ?", arguments: [askID]) }
        }
        let vm = makeVM()
        let ask = try await openAsk(vm, project: p, id: askID)
        pick(vm, askID)

        await vm.asks.answer(ask)

        XCTAssertEqual(statusWhenTyped, "answered")
        XCTAssertEqual(typed.count, 2)
        let pasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
        let pasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        XCTAssertEqual(Array(typed[0].prefix(6)), pasteStart)
        XCTAssertEqual(Array(typed[0].suffix(6)), pasteEnd)
        let body = typed[0].dropFirst(6).dropLast(6)
        XCTAssertFalse(body.contains { $0 < 0x20 || $0 == 0x7F }, "one line: no CR, LF or other control byte inside the paste")
        XCTAssertEqual(typed[1], [0x0D], "Return comes alone, after the paste")
    }

    /// PROJ-12 (amended 2026-10-04): while the session waits on a permission
    /// prompt nothing is typed — a Return could confirm the prompt's
    /// default. The line goes, pasted and submitted, once the prompt is
    /// answered.
    func testProj12_ASessionAtAPermissionPromptGetsTheLineOnlyAfterTheAnswer() async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        let vm = makeVM()
        var approval = true
        vm.asks.needsApproval = { id in id == s.id && approval }
        center.inputAnswersDialog = { id in id == s.id && approval }
        let ask = try await openAsk(vm, project: p, id: askID)
        vm.asks.openDrawer(askID: askID, projectID: p)
        pick(vm, askID)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .held)
        let stored = try await status(askID)
        XCTAssertEqual(stored.status, "answered", "stored at once")
        XCTAssertTrue(typed.isEmpty, "nothing reaches a permission prompt")
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(vm.asks.answerNotices[askID]?.text, OwnerAsksViewModel.answerHeldNote)
        XCTAssertEqual(center.answerHints[s.id], .held)
        XCTAssertNil(vm.asks.drawerAskIDs[p], "the terminal, where the prompt is answered, takes over")
        XCTAssertNotNil(center.keyboardFocusSerial(for: s.id))

        processes[0].onOwnerInput?(Array("y".utf8))
        await vm.asks.deliverHeldAnswers()
        XCTAssertTrue(typed.isEmpty, "still at the prompt: still held")
        XCTAssertEqual(center.answerHints[s.id], .held, "the owner's input answers the prompt; the hint stays")

        approval = false
        await vm.asks.deliverHeldAnswers()

        let line = OwnerAskPrompt.line(id: askID, kind: .question, answer: try OwnerAskAnswer.decode(stored.answer))
        XCTAssertEqual(typed.count, 2)
        XCTAssertTrue(String(bytes: typed[0], encoding: .utf8)?.contains(line) == true)
        XCTAssertEqual(typed[1], [0x0D])
        XCTAssertEqual(vm.asks.answerNotices[askID]?.text, OwnerAsksViewModel.answerSentNote)
        XCTAssertNil(center.answerHints[s.id])

        await vm.asks.deliverHeldAnswers()
        XCTAssertEqual(typed.count, 2, "delivered once")
    }

    /// PROJ-12 (amended 2026-10-04): a Return would submit what the owner
    /// half-typed in Claude Code's prompt with the answer, so over such text
    /// the line is only pasted — at once or after a hold. Keys answering the
    /// permission dialog leave no draft; the owner's own Return ends one.
    func testProj12_OverTheOwnersHalfTypedTextTheLineIsOnlyPasted() async throws {
        let (p, s, askID) = try await seed()
        let otherID = try await fileAnotherAsk(project: p, sessionID: s.id)
        center.start(s, fresh: true)
        let vm = makeVM()
        await vm.asks.load(projectID: p)
        let asks = try XCTUnwrap(vm.asks.openAsks[p])
        pick(vm, askID)
        pick(vm, otherID)
        processes[0].onOwnerInput?(Array("fix the".utf8))

        let first = await vm.asks.answer(try XCTUnwrap(asks.first { $0.id == askID }))

        XCTAssertEqual(first, .typed)
        XCTAssertEqual(typed.count, 1, "the paste, no Return")
        XCTAssertEqual(center.answerHints[s.id], .typed)

        processes[0].onOwnerInput?([0x0D])
        var approval = true
        vm.asks.needsApproval = { _ in approval }
        center.inputAnswersDialog = { _ in approval }
        let second = await vm.asks.answer(try XCTUnwrap(asks.first { $0.id == otherID }))
        XCTAssertEqual(second, .held)
        processes[0].onOwnerInput?(Array("1".utf8))
        approval = false
        processes[0].onOwnerInput?(Array("next step".utf8))
        await vm.asks.deliverHeldAnswers()

        XCTAssertEqual(typed.count, 2, "the held line pasted over the new draft, no Return")
        XCTAssertFalse(typed.contains([0x0D]))
        XCTAssertEqual(vm.asks.answerNotices[otherID]?.text, OwnerAsksViewModel.answerTypedNote)
    }

    /// The owner's own Return ends a draft, and a key into the permission
    /// dialog starts none: the line is submitted.
    func testAfterTheOwnersReturnOrADialogKeyTheLineIsSubmitted() async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        let vm = makeVM()
        center.inputAnswersDialog = { _ in true }
        processes[0].onOwnerInput?(Array("1".utf8))
        center.inputAnswersDialog = { _ in false }
        processes[0].onOwnerInput?(Array("done".utf8))
        processes[0].onOwnerInput?([0x0D])
        let ask = try await openAsk(vm, project: p, id: askID)
        pick(vm, askID)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .submitted)
        XCTAssertEqual(typed.last, [0x0D])
    }

    /// PROJ-12 (amended 2026-10-04 and 2026-10-07, board #396): only the
    /// session's hooks reporting during this run — a state, or the mark of
    /// a run whose folder has the state hooks — vouch that no permission
    /// prompt is on screen; without them the line is pasted and the owner
    /// presses Return.
    func testProj12_WithoutTheStateHooksTheLineIsOnlyPasted() async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        let vm = makeVM()
        vm.asks.hasHookState = { _ in false }
        let ask = try await openAsk(vm, project: p, id: askID)
        pick(vm, askID)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .typed)
        XCTAssertEqual(typed.count, 1)
        XCTAssertFalse(typed[0].contains(0x0D))
        XCTAssertEqual(center.answerHints[s.id], .typed)
        XCTAssertEqual(vm.asks.answerNotices[askID]?.text, OwnerAsksViewModel.answerTypedNote)
    }

    /// Two answers to one session never share its prompt: a delivery that
    /// starts while another is in its pause waits, then each line is pasted
    /// and submitted in turn.
    func testTwoHeldAnswersToOneSessionGoOneAfterTheOther() async throws {
        let (p, s, askID) = try await seed()
        let otherID = try await fileAnotherAsk(project: p, sessionID: s.id)
        center.start(s, fresh: true)
        let vm = makeVM()
        var approval = true
        vm.asks.needsApproval = { _ in approval }
        await vm.asks.load(projectID: p)
        let asks = try XCTUnwrap(vm.asks.openAsks[p])
        pick(vm, askID)
        pick(vm, otherID)
        for ask in asks {
            let delivery = await vm.asks.answer(ask)
            XCTAssertEqual(delivery, .held)
        }
        approval = false
        var reentered = 0
        onPause = { [weak vm] in
            reentered += 1
            await vm?.asks.deliverHeldAnswers()
        }

        await vm.asks.deliverHeldAnswers()

        XCTAssertEqual(reentered, 2, "a state change during each pause")
        XCTAssertEqual(typed.count, 4)
        let lines = typed.map { String(bytes: $0, encoding: .utf8) ?? "" }
        XCTAssertTrue(lines[0].contains("Ask #\(askID) "))
        XCTAssertEqual(typed[1], [0x0D])
        XCTAssertTrue(lines[2].contains("Ask #\(otherID) "))
        XCTAssertEqual(typed[3], [0x0D])
        XCTAssertEqual(vm.asks.answerNotices[askID], .delivered(.submitted))
        XCTAssertEqual(vm.asks.answerNotices[otherID], .delivered(.submitted))
    }

    /// The held bar's Dismiss cancels the typing: the answer stays saved
    /// and goes to the session's brief.
    func testDismissingAHeldAnswerCancelsItsDelivery() async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        let vm = makeVM()
        var approval = true
        vm.asks.needsApproval = { _ in approval }
        let ask = try await openAsk(vm, project: p, id: askID)
        pick(vm, askID)
        let delivery = await vm.asks.answer(ask)
        XCTAssertEqual(delivery, .held)

        vm.asks.cancelHeldAnswers(sessionID: s.id)
        approval = false
        await vm.asks.deliverHeldAnswers()

        XCTAssertTrue(typed.isEmpty)
        XCTAssertNil(center.answerHints[s.id])
        XCTAssertEqual(vm.asks.answerNotices[askID]?.text, OwnerAsksViewModel.noSessionNote)
        let stored = try await status(askID)
        XCTAssertEqual(stored.status, "answered", "the brief still lists it")
    }

    /// A held line never reaches a session that stopped, or a later run of
    /// it (whose brief listed the answer): it goes nowhere and says so.
    func testAHeldAnswerGoesNowhereOnceItsSessionStops() async throws {
        try await assertHeldAnswerGoesNowhere(restart: false)
    }

    func testAHeldAnswerNeverReachesALaterRunOfItsSession() async throws {
        try await assertHeldAnswerGoesNowhere(restart: true)
    }

    private func assertHeldAnswerGoesNowhere(restart: Bool) async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        let vm = makeVM()
        var approval = true
        vm.asks.needsApproval = { _ in approval }
        let ask = try await openAsk(vm, project: p, id: askID)
        pick(vm, askID)
        let delivery = await vm.asks.answer(ask)
        XCTAssertEqual(delivery, .held)

        processes[0].onExit?(0)
        if restart {
            // The same instant and the same process object: only the run
            // number tells the relaunch apart (board #387).
            center.start(s, fresh: false)
            XCTAssertEqual(center.states[s.id], .running)
        }
        approval = false
        await vm.asks.deliverHeldAnswers()

        XCTAssertTrue(typed.isEmpty)
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(vm.asks.answerNotices[askID]?.text, OwnerAsksViewModel.noSessionNote, "the brief lists it")
        XCTAssertNil(center.answerHints[s.id])
    }

    /// Board #388: the owner pressed Return while the line waited out its
    /// pause — that sent it. No Return of ours follows into the empty
    /// prompt, and no "press Return" bar is left behind.
    func testTheOwnersReturnDuringThePauseSendsTheAnswer() async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        let vm = makeVM()
        onPause = { [weak self] in self?.processes[0].onOwnerInput?([0x0D]) }
        let ask = try await openAsk(vm, project: p, id: askID)
        pick(vm, askID)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .submitted)
        XCTAssertEqual(typed.count, 1, "the paste only")
        XCTAssertFalse(typed.contains([0x0D]))
        XCTAssertNil(center.answerHints[s.id])
        XCTAssertFalse(center.pasteHints.contains(s.id))
        XCTAssertEqual(vm.asks.answerNotices[askID]?.text, OwnerAsksViewModel.answerSentNote)
    }

    /// Board #387: a relaunch of the session while the line waits for its
    /// Return reuses the process object; the Return never goes into the new
    /// run, and the answer is left for that run's brief.
    func testARelaunchDuringThePauseGetsNoReturn() async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        let vm = makeVM()
        onPause = { [weak self] in
            guard let self else { return }
            processes[0].onExit?(0)
            center.start(s, fresh: false)
        }
        let ask = try await openAsk(vm, project: p, id: askID)
        pick(vm, askID)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(processes.count, 1, "the relaunch reused the process")
        XCTAssertEqual(delivery, .noSession)
        XCTAssertEqual(typed.count, 1, "the paste into the old run, no Return into the new one")
        XCTAssertFalse(typed.contains([0x0D]))
        XCTAssertEqual(vm.asks.answerNotices[askID]?.text, OwnerAsksViewModel.noSessionNote, "the brief lists it")
    }

    /// Board #387: a relaunch during the state read before the paste is a
    /// new run too: nothing is typed into it.
    func testARelaunchDuringTheReadBeforeThePasteTypesNothing() async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        let vm = makeVM()
        var reads = 0
        vm.asks.refreshStates = { [weak self] in
            reads += 1
            if reads == 1, let self {
                processes[0].onExit?(0)
                center.start(s, fresh: false)
            }
            return true
        }
        let ask = try await openAsk(vm, project: p, id: askID)
        pick(vm, askID)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .noSession)
        XCTAssertTrue(typed.isEmpty)
        XCTAssertEqual(center.states[s.id], .running)
    }

    /// A permission prompt that appears during the pause between the paste
    /// and Return stops the Return: the pane says to press it. The owner's
    /// key into that prompt leaves the line unsent in Claude Code's prompt,
    /// so the hint stays, and the next answer is only pasted after it —
    /// two answers never go as one message (PROJ-12).
    func testAPermissionPromptDuringThePauseLeavesTheLineTyped() async throws {
        let (p, s, askID) = try await seed()
        let otherID = try await fileAnotherAsk(project: p, sessionID: s.id)
        center.start(s, fresh: true)
        let vm = makeVM()
        await vm.asks.load(projectID: p)
        let asks = try XCTUnwrap(vm.asks.openAsks[p])
        var refreshes = 0
        vm.asks.refreshStates = {
            refreshes += 1
            return true
        }
        var approval: Bool { refreshes == 2 }
        vm.asks.needsApproval = { _ in approval }
        center.inputAnswersDialog = { _ in approval }
        pick(vm, askID)
        pick(vm, otherID)

        let delivery = await vm.asks.answer(try XCTUnwrap(asks.first { $0.id == askID }))

        XCTAssertEqual(delivery, .typed)
        XCTAssertEqual(refreshes, 2, "read before the paste and after the pause")
        XCTAssertEqual(typed.count, 1, "the paste, no Return")
        XCTAssertEqual(center.answerHints[s.id], .typed)
        XCTAssertEqual(vm.asks.answerNotices[askID]?.text, OwnerAsksViewModel.answerTypedNote)
        processes[0].onOwnerInput?(Array("1".utf8))
        XCTAssertEqual(center.answerHints[s.id], .typed, "a key into the permission dialog sends nothing of the line")

        refreshes = 3
        let second = await vm.asks.answer(try XCTUnwrap(asks.first { $0.id == otherID }))
        XCTAssertEqual(second, .typed)
        XCTAssertEqual(typed.count, 2, "pasted after the first line")
        XCTAssertFalse(typed.contains([0x0D]), "no Return submits the two lines as one message")

        processes[0].onOwnerInput?([0x0D])
        XCTAssertNil(center.answerHints[s.id], "the owner's Return")
    }

    /// PROJ-12: a hand-off left pasted without its Return (its session was
    /// not idle) is still in the prompt; an answer is only pasted after it,
    /// never submitting text the owner did not send.
    func testAHandOffLeftWithoutItsReturnKeepsTheAnswerFromSubmittingIt() async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        let vm = makeVM()
        let handOff = await center.submitPrompt("From a Watchtower code question", sessionID: s.id) { false }
        XCTAssertEqual(handOff, .pasted)
        let ask = try await openAsk(vm, project: p, id: askID)
        pick(vm, askID)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .typed)
        XCTAssertEqual(typed.count, 2)
        XCTAssertFalse(typed.contains([0x0D]))
    }

    /// PROJ-12: a state read that fails after the pause vouches for no
    /// state, so the line is only pasted.
    func testAFailedStateReadAfterThePauseLeavesTheLineTyped() async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        let vm = makeVM()
        var reads = 0
        vm.asks.refreshStates = {
            reads += 1
            return reads != 2
        }
        let ask = try await openAsk(vm, project: p, id: askID)
        pick(vm, askID)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .typed)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(typed.count, 1, "the paste, no Return")
        XCTAssertFalse(typed.contains([0x0D]))
    }

    /// PROJ-12: when the read right before the paste fails, the last good
    /// state may miss a permission prompt shown since — nothing is typed;
    /// the line is held and goes on the next read that succeeds.
    func testAFailedStateReadBeforeThePasteHoldsTheLine() async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        let vm = makeVM()
        var readable = false
        vm.asks.refreshStates = { readable }
        let ask = try await openAsk(vm, project: p, id: askID)
        pick(vm, askID)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .held)
        XCTAssertTrue(typed.isEmpty, "nothing pasted on a stale state")
        XCTAssertEqual(center.answerHints[s.id], .held)

        await vm.asks.deliverHeldAnswers()
        XCTAssertTrue(typed.isEmpty, "still unreadable: still held")

        readable = true
        await vm.asks.deliverHeldAnswers()
        XCTAssertEqual(typed.count, 2)
        XCTAssertEqual(typed.last, [0x0D])
        XCTAssertEqual(vm.asks.answerNotices[askID], .delivered(.submitted))
    }

    /// An answer queued behind another that ended typed (a permission prompt
    /// appeared in its pause) is held by that prompt: its own notice and the
    /// bar say so, and its minute's wait starts — the earlier answer's hint
    /// does not hide that.
    func testAQueuedAnswerHeldByAPromptAfterTheFirstEndedTypedSaysItIsHeld() async throws {
        let (p, s, askID) = try await seed()
        let otherID = try await fileAnotherAsk(project: p, sessionID: s.id)
        center.start(s, fresh: true)
        let vm = makeVM()
        var waits = 0
        vm.asks.holdSleep = { _ in
            waits += 1
            try? await Task.sleep(for: .seconds(3600))
        }
        await vm.asks.load(projectID: p)
        let asks = try XCTUnwrap(vm.asks.openAsks[p])
        pick(vm, askID)
        pick(vm, otherID)
        let other = try XCTUnwrap(asks.first { $0.id == otherID })
        var approval = false
        vm.asks.needsApproval = { _ in approval }
        var queued: OwnerAsksViewModel.Delivery?
        onPause = { [weak vm] in
            guard let vm, queued == nil else { return }
            queued = await vm.asks.answer(other)
            approval = true // a permission prompt appears during the first pause
        }

        let first = await vm.asks.answer(try XCTUnwrap(asks.first { $0.id == askID }))

        XCTAssertEqual(first, .typed)
        XCTAssertEqual(queued, .queued)
        await waitUntil { vm.asks.answerNotices[otherID] == .delivered(.held) }
        XCTAssertEqual(vm.asks.answerNotices[otherID]?.text, OwnerAsksViewModel.answerHeldNote)
        XCTAssertEqual(center.answerHints[s.id], .held)
        await waitUntil { waits == 1 }
        XCTAssertEqual(typed.count, 1, "only the first line, no Return")
    }

    /// An answer written while another is going to the same session (in
    /// its pause) waits behind it with its own note — not the permission
    /// prompt's — and goes right after it, pasted and submitted, without a
    /// state change.
    func testAnAnswerDuringAnotherAnswersPauseIsQueuedThenGoesNext() async throws {
        let (p, s, askID) = try await seed()
        let otherID = try await fileAnotherAsk(project: p, sessionID: s.id)
        center.start(s, fresh: true)
        let vm = makeVM()
        await vm.asks.load(projectID: p)
        let asks = try XCTUnwrap(vm.asks.openAsks[p])
        pick(vm, askID)
        pick(vm, otherID)
        let other = try XCTUnwrap(asks.first { $0.id == otherID })
        var queued: OwnerAsksViewModel.Delivery?
        onPause = { [weak self, weak vm] in
            guard let self, let vm, queued == nil else { return }
            queued = await vm.asks.answer(other)
            XCTAssertEqual(vm.asks.answerNotices[otherID]?.text, OwnerAsksViewModel.answerQueuedNote)
            XCTAssertEqual(center.answerHints[s.id], .queued)
            XCTAssertEqual(typed.count, 1, "nothing of the second line yet")
        }

        let first = await vm.asks.answer(try XCTUnwrap(asks.first { $0.id == askID }))

        XCTAssertEqual(first, .submitted)
        XCTAssertEqual(queued, .queued)
        await waitUntil { self.typed.count == 4 }
        guard typed.count == 4 else { return }
        let lines = typed.map { String(bytes: $0, encoding: .utf8) ?? "" }
        XCTAssertTrue(lines[0].contains("Ask #\(askID) "))
        XCTAssertEqual(typed[1], [0x0D])
        XCTAssertTrue(lines[2].contains("Ask #\(otherID) "))
        XCTAssertEqual(typed[3], [0x0D])
        await waitUntil { vm.asks.answerNotices[otherID] == .delivered(.submitted) }
        XCTAssertNil(center.answerHints[s.id])
    }

    /// A line held behind a permission prompt is never sent on a timer:
    /// after `stillHeldAfter` the bar says it still waits (Dismiss hands it
    /// to the brief), and the line goes only once the prompt is answered.
    func testALongHeldAnswerSaysItStillWaitsAndIsNeverSentOnATimer() async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        let vm = makeVM()
        var waited: [Duration] = []
        vm.asks.holdSleep = { waited.append($0) }
        var approval = true
        vm.asks.needsApproval = { _ in approval }
        let ask = try await openAsk(vm, project: p, id: askID)
        pick(vm, askID)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .held)
        await waitUntil { self.center.answerHints[s.id] == .stillHeld }
        XCTAssertEqual(waited, [OwnerAsksViewModel.stillHeldAfter])
        XCTAssertEqual(OwnerAsksViewModel.stillHeldAfter, .seconds(60))
        XCTAssertTrue(typed.isEmpty, "still held: nothing typed")
        XCTAssertTrue(OwnerAsksViewModel.answerStillHeldNote.contains("Dismiss"))

        approval = false
        await vm.asks.deliverHeldAnswers()
        XCTAssertEqual(typed.count, 2)
        XCTAssertEqual(typed.last, [0x0D])
        XCTAssertNil(center.answerHints[s.id])
    }

    /// A line held again (the prompt came back right before its paste)
    /// starts its wait anew: the first hold's wait does not mark it.
    func testOnlyTheLatestHoldsWaitMarksItStillWaiting() async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        let vm = makeVM()
        var wakes: [CheckedContinuation<Void, Never>] = []
        vm.asks.holdSleep = { _ in await withCheckedContinuation { wakes.append($0) } }
        var approval = true
        vm.asks.needsApproval = { _ in approval }
        let ask = try await openAsk(vm, project: p, id: askID)
        pick(vm, askID)
        let delivery = await vm.asks.answer(ask)
        XCTAssertEqual(delivery, .held)
        await waitUntil { wakes.count == 1 }

        approval = false
        vm.asks.refreshStates = {
            approval = true
            return true
        }
        await vm.asks.deliverHeldAnswers()
        XCTAssertTrue(typed.isEmpty, "held again")
        await waitUntil { wakes.count == 2 }
        guard wakes.count == 2 else { return }
        wakes[0].resume()
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(center.answerHints[s.id], .held)
        wakes[1].resume()
        await waitUntil { self.center.answerHints[s.id] == .stillHeld }
    }

    /// A hold that ended before the wait is over never turns into "still
    /// waiting".
    func testAHoldThatEndedBeforeTheWaitIsNotMarkedStillWaiting() async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        let vm = makeVM()
        var wakes: [CheckedContinuation<Void, Never>] = []
        vm.asks.holdSleep = { _ in await withCheckedContinuation { wakes.append($0) } }
        var approval = true
        vm.asks.needsApproval = { _ in approval }
        let ask = try await openAsk(vm, project: p, id: askID)
        pick(vm, askID)
        let delivery = await vm.asks.answer(ask)
        XCTAssertEqual(delivery, .held)
        await waitUntil { wakes.count == 1 }

        approval = false
        await vm.asks.deliverHeldAnswers()
        XCTAssertNil(center.answerHints[s.id], "delivered")
        let other = try await fileAnotherAsk(project: p, sessionID: s.id)
        approval = true
        await vm.asks.load(projectID: p)
        pick(vm, other)
        let held = await vm.asks.answer(try XCTUnwrap(vm.asks.openAsks[p]?.first { $0.id == other }))
        XCTAssertEqual(held, .held)
        await waitUntil { wakes.count == 2 }
        guard wakes.count == 2 else { return }
        wakes[0].resume()
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(center.answerHints[s.id], .held, "the first hold's wait does not mark the second")
        wakes[1].resume()
        await waitUntil { self.center.answerHints[s.id] == .stillHeld }
    }

    func testCopiedShowsTheCopiedAnswerHint() async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        processes[0].bracketedPasteMode = false
        let vm = makeVM()
        let ask = try await openAsk(vm, project: p, id: askID)
        vm.asks.openDrawer(askID: askID, projectID: p)
        pick(vm, askID)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .copied)
        XCTAssertTrue(typed.isEmpty, "no keystrokes, and no Return, reach the terminal")
        XCTAssertEqual(copied.count, 1)
        XCTAssertEqual(center.answerHints[s.id], .copied, "the session's pane says to paste, then press Return")
        XCTAssertFalse(center.clipboardHints.contains(s.id), "in place of the generic clipboard hint")
        XCTAssertEqual(vm.asks.answerNotices[askID]?.text, OwnerAsksViewModel.answerCopiedNote)
        XCTAssertNil(vm.asks.drawerAskIDs[p])
        XCTAssertNotNil(center.keyboardFocusSerial(for: s.id))
    }

    func testNoSessionWritesTheAnswerTypesNothingAndSaysTheBriefGetsIt() async throws {
        let (p, s, askID) = try await seed()
        let vm = makeVM()
        let ask = try await openAsk(vm, project: p, id: askID)
        vm.asks.openDrawer(askID: askID, projectID: p)
        pick(vm, askID)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .noSession)
        let stored = try await status(askID)
        XCTAssertEqual(stored.status, "answered")
        XCTAssertTrue(processes.isEmpty, "answering never starts a session")
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(vm.asks.answerNotices[askID]?.text, OwnerAsksViewModel.noSessionNote)
        XCTAssertEqual(vm.asks.drawerAskIDs[p], askID, "nothing went to a terminal: the drawer stays")
        XCTAssertNil(center.keyboardFocusSerial(for: s.id))
        XCTAssertNil(center.answerHints[s.id], "no Return hint for a line that went nowhere")
    }

    func testAnAskFiledOutsideTheAppIsWrittenAndNothingIsTyped() async throws {
        let (p, s, askID) = try await seed(session: false)
        center.start(s, fresh: true)
        let vm = makeVM()
        let ask = try await openAsk(vm, project: p, id: askID)
        pick(vm, askID)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .noSession)
        let stored = try await status(askID)
        XCTAssertEqual(stored.status, "answered")
        XCTAssertTrue(typed.isEmpty, "a live session of the workbench is not the ask's")
    }

    func testAnAskWithdrawnMeanwhileWritesNothingKeepsTheDraftAndSaysSo() async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        let vm = makeVM()
        let ask = try await openAsk(vm, project: p, id: askID)
        vm.asks.openDrawer(askID: askID, projectID: p)
        vm.asks.drafts.update(askID) {
            $0.picks["a"] = .init(labels: ["Yes"])
            $0.note = "Ship it"
        }
        try await pool.write { d in
            try d.execute(sql: "UPDATE owner_asks SET status = 'withdrawn', withdrawn_reason = 'agent' WHERE id = ?", arguments: [askID])
        }

        let delivery = await vm.asks.answer(ask)

        XCTAssertNil(delivery)
        let stored = try await status(askID)
        XCTAssertEqual(stored.status, "withdrawn")
        XCTAssertEqual(stored.answer, "")
        XCTAssertTrue(typed.isEmpty)
        XCTAssertEqual(vm.asks.drafts.askDraft(for: askID).note, "Ship it", "the draft is kept")
        XCTAssertEqual(vm.asks.answerNotices[askID], .withdrawn)
        XCTAssertEqual(vm.asks.answerNotices[askID]?.text, OwnerAsksViewModel.withdrawnNote)
        XCTAssertEqual(vm.asks.openAsks[p], [], "the list catches up")
        XCTAssertEqual(vm.asks.drawerAskIDs[p], askID)
    }

    func testADoubleClickOnAnswerWritesOnce() async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        let vm = makeVM()
        let ask = try await openAsk(vm, project: p, id: askID)
        pick(vm, askID)

        async let first = vm.asks.answer(ask)
        async let second = vm.asks.answer(ask)
        let results = await [first, second]

        XCTAssertEqual(results.compactMap { $0 }, [.submitted], "one click answers, the other is refused")
        XCTAssertEqual(typed.count, 2, "one paste and its Return")
        XCTAssertEqual(vm.asks.answerNotices[askID], .delivered(.submitted), "the second click never reads as withdrawn")
        XCTAssertTrue(vm.asks.answering.isEmpty)
    }

    func testAnIncompleteDraftWritesNothing() async throws {
        let (p, _, askID) = try await seed()
        let vm = makeVM()
        let ask = try await openAsk(vm, project: p, id: askID)

        let delivery = await vm.asks.answer(ask)

        XCTAssertNil(delivery)
        let stored = try await status(askID)
        XCTAssertEqual(stored.status, "open", "a question without a pick is not an answer")
    }

    // MARK: - Quick asks (spec 2026-10-10 Part 9)

    /// Stores `askID` as a Quick ask (Go classifies; the test sets it).
    private func makeQuick(_ askID: Int64) async throws {
        try await pool.write { d in
            try d.execute(sql: "UPDATE owner_asks SET level = 'quick' WHERE id = ?", arguments: [askID])
        }
    }

    private func quickRow(_ vm: WorkbenchesViewModel, project: Int64, id: Int64) async throws -> (OwnerAsk, OwnerAskQuickRow) {
        let ask = try await openAsk(vm, project: project, id: id)
        return (ask, try XCTUnwrap(OwnerAskQuickRow(ask: ask)))
    }

    /// PROJ-12 (spec 2026-10-10 Part 11.2, E28): a tap in the banner is an
    /// answer in the Desktop like the drawer's — the same stored answer and
    /// line bytes, stored before anything is typed, then the same paste,
    /// pause and Return rules: held at a permission prompt, only pasted over
    /// the owner's draft.
    func testProj12_AQuickAnswerFromTheBannerIsStoredThenDeliveredLikeTheDrawers() async throws {
        let (p, s, drawerID) = try await seed()
        let quickIDs = [
            try await fileAnotherAsk(project: p, sessionID: s.id),
            try await fileAnotherAsk(project: p, sessionID: s.id),
            try await fileAnotherAsk(project: p, sessionID: s.id)
        ]
        for id in quickIDs { try await makeQuick(id) }
        center.start(s, fresh: true)
        let vm = makeVM()
        let drawerAsk = try await openAsk(vm, project: p, id: drawerID)
        pick(vm, drawerID)
        let drawerDelivery = await vm.asks.answer(drawerAsk)
        XCTAssertEqual(drawerDelivery, .submitted)
        let drawerBytes = typed

        // Submitted: the same stored answer and, but for the id, the same bytes.
        var statusWhenTyped: String?
        processes[0].onInput = { [pool] in
            statusWhenTyped = try? pool?.read {
                try String.fetchOne($0, sql: "SELECT status FROM owner_asks WHERE id = ?", arguments: [quickIDs[0]])
            }
        }
        let (first, firstRow) = try await quickRow(vm, project: p, id: quickIDs[0])
        let firstDelivery = await vm.answerQuick(first, with: firstRow.answer(picking: "Yes"))
        processes[0].onInput = nil

        XCTAssertEqual(firstDelivery, .delivered(.submitted))
        XCTAssertEqual(statusWhenTyped, "answered", "stored before the line is typed")
        let drawerStored = try await status(drawerID)
        let quickStored = try await status(quickIDs[0])
        XCTAssertEqual(quickStored.answer, drawerStored.answer, "the drawer's answer, byte for byte")
        XCTAssertEqual(typed.count, 4, "one paste and its Return each")
        let swapped = try XCTUnwrap(String(bytes: drawerBytes[0], encoding: .utf8))
            .replacingOccurrences(of: "#\(drawerID)", with: "#\(quickIDs[0])")
            .replacingOccurrences(of: "get_ask \(drawerID)", with: "get_ask \(quickIDs[0])")
        XCTAssertEqual(String(bytes: typed[2], encoding: .utf8), swapped)
        XCTAssertEqual(typed[3], [0x0D], "Return comes alone, after the paste")
        XCTAssertEqual(vm.asks.answerNotices[quickIDs[0]]?.text, OwnerAsksViewModel.answerSentNote)

        // A permission prompt holds the line until it is answered.
        var approval = true
        vm.asks.needsApproval = { id in id == s.id && approval }
        center.inputAnswersDialog = { id in id == s.id && approval }
        let (second, secondRow) = try await quickRow(vm, project: p, id: quickIDs[1])
        let secondDelivery = await vm.answerQuick(second, with: secondRow.answer(picking: "No"))
        XCTAssertEqual(secondDelivery, .delivered(.held))
        let held = try await status(quickIDs[1])
        XCTAssertEqual(held.status, "answered", "stored at once")
        XCTAssertEqual(typed.count, 4, "nothing reaches a permission prompt")
        approval = false
        await vm.asks.deliverHeldAnswers()
        XCTAssertEqual(typed.count, 6)
        XCTAssertEqual(typed[5], [0x0D])

        // Over the owner's half-typed text the line is only pasted.
        processes[0].onOwnerInput?(Array("fix the".utf8))
        let (third, thirdRow) = try await quickRow(vm, project: p, id: quickIDs[2])
        let thirdDelivery = await vm.answerQuick(third, with: thirdRow.answer(picking: "Yes"))
        XCTAssertEqual(thirdDelivery, .delivered(.typed))
        XCTAssertEqual(typed.count, 7, "the paste, no Return")
        XCTAssertNotEqual(typed.last, [0x0D])
        XCTAssertEqual(center.answerHints[s.id], .typed)
    }

    /// PROJ-12 (spec 2026-10-10 Part 11.2): a Reply goes as the question's
    /// "other" on one line — line breaks and control characters as spaces,
    /// trimmed, at most 500 runes — and a blank one sends nothing.
    func testProj12_AReplyIsSentAsOtherOnOneLine() async throws {
        let (p, s, askID) = try await seed()
        let longID = try await fileAnotherAsk(project: p, sessionID: s.id)
        try await makeQuick(askID)
        try await makeQuick(longID)
        center.start(s, fresh: true)
        let vm = makeVM()
        let (ask, row) = try await quickRow(vm, project: p, id: askID)

        XCTAssertNil(row.reply("  \n\t "), "blank: no answer, so the view sends nothing")
        let reply = try XCTUnwrap(row.reply("  use the\nstaging\u{7}host \r\n"))
        let delivery = await vm.answerQuick(ask, with: reply)

        XCTAssertEqual(delivery, .delivered(.submitted))
        let stored = try OwnerAskAnswer.decode(try await status(askID).answer)
        XCTAssertEqual(stored.answers, [.init(id: "a", labels: [], other: "use the staging host")])
        let body = typed[0].dropFirst(6).dropLast(6)
        XCTAssertFalse(body.contains { $0 < 0x20 || $0 == 0x7F }, "one line: no control byte inside the paste")

        let (long, longRow) = try await quickRow(vm, project: p, id: longID)
        await vm.answerQuick(long, with: try XCTUnwrap(longRow.reply(String(repeating: "é", count: 600))))
        let longStored = try OwnerAskAnswer.decode(try await status(longID).answer)
        XCTAssertEqual(longStored.answers.first?.other.unicodeScalars.count, 500)
    }

    /// E29: the agent withdrew the ask while the owner tapped — nothing is
    /// written or typed, the card leaves the banner and the stack, and the
    /// drawer beside the session's terminal on screen shows the "withdrawn"
    /// note.
    func testAQuickTapOnAWithdrawnAskTypesNothing() async throws {
        let (p, s, askID) = try await seed()
        try await makeQuick(askID)
        center.start(s, fresh: true)
        let vm = makeVM()
        vm.selectedWorkbenchID = p
        vm.layout.show(.session(s.id))
        let (ask, row) = try await quickRow(vm, project: p, id: askID)
        try await pool.write { d in
            try d.execute(sql: "UPDATE owner_asks SET status = 'withdrawn', withdrawn_reason = 'agent' WHERE id = ?", arguments: [askID])
        }

        let delivery = await vm.answerQuick(ask, with: row.answer(picking: "Yes"))

        XCTAssertEqual(delivery, .notOpen)
        let stored = try await status(askID)
        XCTAssertEqual(stored.status, "withdrawn")
        XCTAssertEqual(stored.answer, "")
        XCTAssertTrue(typed.isEmpty)
        XCTAssertEqual(vm.asks.stack(projectID: p).asks, [], "the card is removed")
        XCTAssertEqual(vm.asks.answerNotices[askID]?.text, OwnerAsksViewModel.withdrawnNote)
        XCTAssertEqual(vm.asks.drawerAskIDs[p], askID, "the drawer shows the note")
        XCTAssertEqual(vm.asks.drawerAsk(projectID: p)?.status, .withdrawn)
    }

    /// A withdrawn ask tapped from the stack while its session is not on
    /// screen, or while another workbench is selected, changes no page: the
    /// notice alone says so, where the owner tapped.
    func testAQuickTapOnAWithdrawnAskOffScreenOnlyLeavesTheNotice() async throws {
        let (p, s, askID) = try await seed()
        try await makeQuick(askID)
        let vm = makeVM()
        vm.selectedWorkbenchID = p
        vm.layout.show(.board)
        let (ask, row) = try await quickRow(vm, project: p, id: askID)
        try await pool.write { d in
            try d.execute(sql: "UPDATE owner_asks SET status = 'withdrawn', withdrawn_reason = 'agent' WHERE id = ?", arguments: [askID])
        }

        let result = await vm.answerQuick(ask, with: row.answer(picking: "Yes"))

        XCTAssertEqual(result, .notOpen)
        XCTAssertNil(vm.asks.drawerAskIDs[p], "no drawer beside a terminal not on screen")
        XCTAssertFalse(vm.layout(projectID: p).visiblePanes.contains(.session(s.id)), "the page stays as it was")
        XCTAssertEqual(vm.asks.quickNotices(projectID: p).map(\.notice), [.withdrawn])

        let otherID = try await fileAnotherAsk(project: p, sessionID: s.id)
        try await makeQuick(otherID)
        let (other, otherRow) = try await quickRow(vm, project: p, id: otherID)
        try await pool.write { d in
            try d.execute(sql: "UPDATE owner_asks SET status = 'withdrawn', withdrawn_reason = 'agent' WHERE id = ?", arguments: [otherID])
        }
        vm.selectedWorkbenchID = nil
        _ = await vm.answerQuick(other, with: otherRow.answer(picking: "No"))
        XCTAssertNil(vm.selectedWorkbenchID, "no drill into the ask's workbench")
        XCTAssertNil(vm.asks.drawerAskIDs[p])
    }

    /// F1: a Quick answer to a session not running goes to the brief, and
    /// says so where the owner tapped until dismissed; a sent one needs no
    /// notice there.
    func testAQuickAnswerToAStoppedSessionLeavesItsNoticeWhereTheOwnerTapped() async throws {
        let (p, _, askID) = try await seed()
        try await makeQuick(askID)
        let vm = makeVM()
        let (ask, row) = try await quickRow(vm, project: p, id: askID)

        let result = await vm.answerQuick(ask, with: row.answer(picking: "No"))

        XCTAssertEqual(result, .delivered(.noSession))
        let notices = vm.asks.quickNotices(projectID: p)
        XCTAssertEqual(notices.map(\.id), [askID])
        XCTAssertEqual(notices.first?.notice.text, OwnerAsksViewModel.noSessionNote)
        XCTAssertTrue(vm.asks.stack(projectID: p).asks.isEmpty, "the card is gone, the notice stays")
        vm.asks.dismissNotice(askID: askID)
        XCTAssertTrue(vm.asks.quickNotices(projectID: p).isEmpty)
    }

    /// A Quick answer that reached Claude keeps no notice entry — sent at
    /// once, or later once its permission prompt is resolved.
    func testASentQuickAnswerKeepsNoNoticeEntry() async throws {
        let (p, s, askID) = try await seed()
        let heldID = try await fileAnotherAsk(project: p, sessionID: s.id)
        try await makeQuick(askID)
        try await makeQuick(heldID)
        center.start(s, fresh: true)
        let vm = makeVM()
        let (ask, row) = try await quickRow(vm, project: p, id: askID)
        let (heldAsk, heldRow) = try await quickRow(vm, project: p, id: heldID)

        let sent = await vm.answerQuick(ask, with: row.answer(picking: "Yes"))
        XCTAssertEqual(sent, .delivered(.submitted))
        XCTAssertNil(vm.asks.quickAnswered[askID])

        var approval = true
        vm.asks.needsApproval = { _ in approval }
        let held = await vm.answerQuick(heldAsk, with: heldRow.answer(picking: "No"))
        XCTAssertEqual(held, .delivered(.held))
        XCTAssertEqual(vm.asks.quickNotices(projectID: p).map(\.id), [heldID])
        approval = false
        await vm.asks.deliverHeldAnswers()
        XCTAssertEqual(vm.asks.answerNotices[heldID], .delivered(.submitted))
        XCTAssertNil(vm.asks.quickAnswered[heldID])
        XCTAssertTrue(vm.asks.quickNotices(projectID: p).isEmpty)
    }

    /// F4: an answer Go's reader would refuse — here a label that is no
    /// option of the question — is never written or typed.
    func testAQuickAnswerWithAnUnknownLabelWritesNothing() async throws {
        let (p, s, askID) = try await seed()
        try await makeQuick(askID)
        center.start(s, fresh: true)
        let vm = makeVM()
        let ask = try await openAsk(vm, project: p, id: askID)

        let result = await vm.answerQuick(ask, with: .quick(label: "Maybe", questionID: "a"))

        XCTAssertEqual(result, .invalid(#"answers[0].labels: question "a" has no option "Maybe""#))
        let stored = try await status(askID)
        XCTAssertEqual(stored.status, "open")
        XCTAssertTrue(typed.isEmpty)
        XCTAssertNotNil(vm.asks.answerErrors[askID])
        XCTAssertTrue(vm.asks.quickNotices(projectID: p).isEmpty)
    }

    /// F6: once a Quick answer is written its card has no live buttons, even
    /// when the read after it failed and the last list still names it.
    func testAWrittenQuickAnswerLeavesNoLiveButtonsWhenTheReloadFails() async throws {
        let (p, s, askID) = try await seed()
        try await makeQuick(askID)
        center.start(s, fresh: true)
        let vm = makeVM()
        let (ask, row) = try await quickRow(vm, project: p, id: askID)
        onPause = { [pool] in
            // Every read after the paste fails.
            try? await pool?.write { try $0.execute(sql: "ALTER TABLE owner_asks RENAME TO owner_asks_away") }
        }

        let result = await vm.answerQuick(ask, with: row.answer(picking: "Yes"))
        try await pool.write { try $0.execute(sql: "ALTER TABLE owner_asks_away RENAME TO owner_asks") }

        XCTAssertEqual(result, .delivered(.submitted))
        XCTAssertNotNil(vm.asks.loadErrors[p], "the reload failed")
        XCTAssertFalse(vm.asks.stack(projectID: p).asks.contains { $0.id == askID }, "the card is gone")
        XCTAssertFalse(OwnerAskQuickRow.isEnabled(answering: vm.asks.isAnswering(askID), answered: vm.asks.isAnswered(askID)))
    }

    /// While a tap's answer is being written the row's buttons are off, and
    /// a second tap writes nothing.
    func testButtonsDisabledWhileAnswering() async throws {
        let (p, s, askID) = try await seed()
        try await makeQuick(askID)
        center.start(s, fresh: true)
        let vm = makeVM()
        let (ask, row) = try await quickRow(vm, project: p, id: askID)
        var enabledDuringThePause = true
        var secondTap: OwnerAsksViewModel.AnswerResult?
        onPause = {
            enabledDuringThePause = OwnerAskQuickRow.isEnabled(answering: vm.asks.isAnswering(askID), answered: vm.asks.isAnswered(askID))
            secondTap = await vm.answerQuick(ask, with: row.answer(picking: "No"))
        }
        XCTAssertTrue(OwnerAskQuickRow.isEnabled(answering: vm.asks.isAnswering(askID), answered: vm.asks.isAnswered(askID)))

        let delivery = await vm.answerQuick(ask, with: row.answer(picking: "Yes"))

        XCTAssertEqual(delivery, .delivered(.submitted))
        XCTAssertFalse(enabledDuringThePause)
        XCTAssertEqual(secondTap, .busy, "the second tap is refused")
        XCTAssertNil(vm.asks.drawerAskIDs[p], "a refused tap opens nothing")
        XCTAssertFalse(vm.asks.isAnswering(askID))
        let stored = try OwnerAskAnswer.decode(try await status(askID).answer)
        XCTAssertEqual(stored.answers.first?.labels, ["Yes"])
        XCTAssertEqual(typed.count, 2, "one paste and its Return")
    }

    // MARK: - Agents working (#411)

    /// A running Claude Code session with one open ask filed from it, read
    /// through the real state center: its row holds `agentState` written
    /// this run and a fresh count of 2 background agents.
    private func seedBackgroundSession(
        agentState: String
    ) async throws -> (vm: WorkbenchesViewModel, session: TerminalSession, ask: OwnerAsk) {
        let acme = folder.path
        let (p, s, askID) = try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, folder: acme)
            let s = try TerminalSessionQueries.create(d, .init(
                projectID: p, kind: .claude, title: "claude", folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
            ))
            let ask = try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s.id, payload: Self.questions)
            return (p, s, ask)
        }
        center.transcriptExists = { _ in false }
        center.start(s, fresh: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let reported = formatter.string(from: Date().addingTimeInterval(-1))
        try await pool.write { d in
            try d.execute(sql: """
                UPDATE terminal_sessions SET agent_state = ?, agent_state_at = '2999-01-01T00:00:00.000Z',
                    agent_background = 2, agent_background_at = ? WHERE id = ?
                """, arguments: [agentState, reported, s.id])
        }
        let states = SessionAgentStateCenter(
            dbPool: pool, terminalCenter: center, notifier: RecordingSessionNotifier(), defaults: defaults
        )
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: center, agentStates: states)
        vm.asks.holdSleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
        await states.poll()
        let ask = try await openAsk(vm, project: p, id: askID)
        pick(vm, askID)
        return (vm, s, ask)
    }

    /// PROJ-12 (#411, spec §5.4): Agents working is a turn end — the agent
    /// sits at its prompt while its background agents run — so an answer
    /// gets its Return exactly as into a stopped session.
    func testProj12_AnAnswerIntoABackgroundSessionGetsTheReturn() async throws {
        let (vm, s, ask) = try await seedBackgroundSession(agentState: "waiting")
        XCTAssertEqual(vm.agentStates?.statuses[s.id]?.state.kind, .background, "the open ask does not outrank it")
        var statusWhenTyped: String?
        processes[0].onInput = { [pool] in
            statusWhenTyped = try? pool?.read {
                try String.fetchOne($0, sql: "SELECT status FROM owner_asks WHERE id = ?", arguments: [ask.id])
            }
        }

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .submitted)
        XCTAssertEqual(statusWhenTyped, "answered")
        XCTAssertEqual(typed.count, 2)
        let pasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
        let pasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        XCTAssertEqual(Array(typed[0].prefix(6)), pasteStart)
        XCTAssertEqual(Array(typed[0].suffix(6)), pasteEnd)
        let body = typed[0].dropFirst(6).dropLast(6)
        XCTAssertFalse(body.contains { $0 < 0x20 || $0 == 0x7F }, "one line: no CR, LF or other control byte inside the paste")
        XCTAssertEqual(typed[1], [0x0D], "Return comes alone, after the paste")
        XCTAssertNil(center.answerHints[s.id])
    }

    /// PROJ-12 (#411, spec §5.4): a background agent's permission prompt
    /// stores `approval` with the count kept — approval outranks Agents
    /// working, and the line is held with nothing typed.
    func testProj12_ABackgroundSessionAtASubagentPermissionPromptHoldsTheLine() async throws {
        let (vm, s, ask) = try await seedBackgroundSession(agentState: "approval")
        XCTAssertEqual(vm.agentStates?.statuses[s.id]?.state.kind, .needsApproval)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .held)
        let stored = try await status(ask.id)
        XCTAssertEqual(stored.status, "answered", "stored at once")
        XCTAssertTrue(typed.isEmpty, "nothing reaches a permission prompt")
        XCTAssertEqual(center.answerHints[s.id], .held)
    }

    // MARK: - Polling

    /// One ask the app cannot read leaves the stack listing the others and
    /// names the broken one, instead of an error over the whole stack.
    func testAnUndecodableAskIsNamedAndTheOthersStillList() async throws {
        let (p, _, good) = try await seed()
        let bad = try await pool.write { d in
            try TestDatabase.insertOwnerAsk(d, projectID: p, payload: #"{"questions":[{"question":"One","options":[{"label":"A"}]}]}"#)
        }
        let vm = makeVM()
        await vm.asks.load(projectID: p)
        XCTAssertEqual(vm.asks.openAsks[p]?.map(\.id), [good])
        XCTAssertEqual(vm.asks.loadErrors[p], "1 ask could not be read (#\(bad)).")

        await vm.asks.loadClosed(projectID: p, sessionID: nil)
        XCTAssertNil(vm.asks.closedErrors[.init(projectID: p, sessionID: nil)], "nothing broken among the closed ones")
        try await pool.write { d in
            try d.execute(sql: "UPDATE owner_asks SET status = 'withdrawn', withdrawn_reason = 'agent' WHERE id = ?", arguments: [bad])
        }
        await vm.asks.load(projectID: p)
        XCTAssertNil(vm.asks.loadErrors[p], "the broken ask left the open list")
        await vm.asks.loadClosed(projectID: p, sessionID: nil)
        XCTAssertEqual(vm.asks.closedLists[.init(projectID: p, sessionID: nil)], [])
        XCTAssertEqual(vm.asks.closedErrors[.init(projectID: p, sessionID: nil)], "1 ask could not be read (#\(bad)).")
    }

    func testThePollReloadsOnlyWhenTheFingerprintChanges() async throws {
        let (p, _, askID) = try await seed()
        let vm = makeVM()
        let first = await vm.asks.refreshIfChanged(projectID: p)
        XCTAssertTrue(first, "a workbench never read counts as changed")
        XCTAssertEqual(vm.asks.openAsks[p]?.map(\.id), [askID])
        let unchanged = await vm.asks.refreshIfChanged(projectID: p)
        XCTAssertFalse(unchanged)

        let filed = try await pool.write { try TestDatabase.insertOwnerAsk($0, projectID: p, title: "Check the build") }
        let afterFiling = await vm.asks.refreshIfChanged(projectID: p)
        XCTAssertTrue(afterFiling)
        XCTAssertEqual(vm.asks.openAsks[p]?.map(\.id), [askID, filed])

        try await pool.write { d in
            try d.execute(sql: "UPDATE owner_asks SET status = 'withdrawn', withdrawn_reason = 'agent' WHERE id = ?", arguments: [filed])
        }
        let afterWithdraw = await vm.asks.refreshIfChanged(projectID: p)
        XCTAssertTrue(afterWithdraw, "a status changed in place moves the fingerprint")
        XCTAssertEqual(vm.asks.openAsks[p]?.map(\.id), [askID])
        let again = await vm.asks.refreshIfChanged(projectID: p)
        XCTAssertFalse(again)
    }

    func testThePollReadsTheWorkbenchOnScreenOnlyWhileTheTabIsVisible() async throws {
        let (p, _, askID) = try await seed()
        let vm = makeVM()
        vm.selectedWorkbenchID = p
        var onScreen = false
        vm.isTabOnScreen = { onScreen }

        await vm.asks.pollTick()
        XCTAssertNil(vm.asks.openAsks[p], "a hidden tab reads nothing")

        onScreen = true
        await vm.asks.pollTick()
        XCTAssertEqual(vm.asks.openAsks[p]?.map(\.id), [askID])
    }

    func testAppActivationRefreshesTheWorkbenchOnScreen() async throws {
        let (p, _, askID) = try await seed()
        let vm = makeVM()
        vm.selectedWorkbenchID = p
        let notifications = NotificationCenter()
        vm.asks.notificationCenter = notifications
        vm.asks.pollSleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
        vm.asks.start()
        defer { vm.asks.stop() }

        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { vm.asks.openAsks[p] != nil }

        XCTAssertEqual(vm.asks.openAsks[p]?.map(\.id), [askID])
    }

    // MARK: - A new ask opens by itself (board #364)

    /// A second open ask filed from `sessionID`, newer than the seeded one.
    private func fileAnotherAsk(project: Int64, sessionID: Int64?) async throws -> Int64 {
        let created = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
        return try await pool.write { d in
            try TestDatabase.insertOwnerAsk(d, projectID: project, sessionID: sessionID, payload: Self.questions, createdAt: created)
        }
    }

    /// `sessionID`'s pane on screen, measured by its view with room for the
    /// drawer beside the terminal (`WorkbenchSessionView`'s geometry hook).
    private func showPane(_ vm: WorkbenchesViewModel, _ sessionID: Int64, project: Int64) {
        vm.layout.show(.session(sessionID))
        vm.sessionPaneMeasured(sessionID, projectID: project, fits: true)
    }

    /// The board on screen; the session pane's view goes (`onDisappear`).
    private func showBoard(_ vm: WorkbenchesViewModel, leaving sessionID: Int64) {
        vm.layout.show(.board)
        vm.asks.setRoomBeside(false, sessionID: sessionID)
    }

    func testANewAskOpensItsDrawerWhenItsSessionIsOnScreenWithoutTakingTheKeyboard() async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        let vm = makeVM()
        vm.selectedWorkbenchID = p
        showPane(vm, s.id, project: p)
        vm.asks.drawerExpanded = true

        await vm.asks.load(projectID: p)

        XCTAssertEqual(vm.asks.drawerAskIDs[p], askID, "no Open click needed")
        XCTAssertFalse(vm.asks.drawerExpanded, "beside the terminal, never covering it")
        XCTAssertNil(center.keyboardFocusRequest, "the keyboard stays where it was")
        XCTAssertFalse(vm.isObscured(sessionID: s.id, projectID: p))
    }

    func testANewAskOpensWhenTheOwnerGoesToItsSession() async throws {
        let (p, s, askID) = try await seed()
        let vm = makeVM()
        vm.selectedWorkbenchID = p
        vm.layout.show(.board)
        await vm.asks.load(projectID: p)
        XCTAssertNil(vm.asks.drawerAskIDs[p], "its session is not on screen")

        showPane(vm, s.id, project: p)

        XCTAssertEqual(vm.asks.drawerAskIDs[p], askID)
    }

    func testAnAskOfAWorkbenchNotOnScreenOpensWhenTheOwnerSwitchesBack() async throws {
        let (p, s, askID) = try await seed()
        let otherFolder = folder.appendingPathComponent("other").path
        let other = try await pool.write { try TestDatabase.insertWorkbench($0, folder: otherFolder) }
        let vm = makeVM()
        var onScreen = WorkspaceLayout.default
        onScreen.show(.session(s.id))
        vm.setLayout(onScreen, projectID: p)
        vm.asks.setRoomBeside(true, sessionID: s.id)
        vm.selectedWorkbenchID = other

        await vm.asks.load(projectID: p)
        XCTAssertNil(vm.asks.drawerAskIDs[p], "a workbench not on screen opens nothing")

        vm.selectedWorkbenchID = p
        await vm.asks.load(projectID: p)
        XCTAssertEqual(vm.asks.drawerAskIDs[p], askID)
    }

    /// Another session's new ask never replaces the drawer the owner has open.
    func testANewAskNeverReplacesAnOpenDrawer() async throws {
        let (p, s, askID) = try await seed()
        let acme = folder.path
        let second = try await pool.write { d in
            try TerminalSessionQueries.create(d, .init(projectID: p, kind: .shell, title: "zsh 2", folderPath: acme))
        }
        let vm = makeVM()
        vm.selectedWorkbenchID = p
        vm.layout.show(.session(second.id))
        vm.layout.split(with: .session(s.id))
        vm.sessionPaneMeasured(second.id, projectID: p, fits: true)
        vm.sessionPaneMeasured(s.id, projectID: p, fits: true)
        await vm.asks.load(projectID: p)
        XCTAssertEqual(vm.asks.drawerAskIDs[p], askID)
        vm.asks.drawerExpanded = true

        // Without the guard the drawer would be opened again, collapsed.
        _ = try await fileAnotherAsk(project: p, sessionID: second.id)
        await vm.asks.refreshIfChanged(projectID: p)

        XCTAssertEqual(vm.asks.drawerAskIDs[p], askID)
        XCTAssertTrue(vm.asks.drawerExpanded, "the open drawer is left as the owner set it")
    }

    /// A pane too narrow for the drawer beside its terminal — or not
    /// measured yet — would be covered while it may hold the keyboard: its
    /// ask waits behind the banner until the pane measures itself with room.
    func testAPaneOpensNothingUntilItIsMeasuredWithRoom() async throws {
        let (p, s, askID) = try await seed()
        let vm = makeVM()
        vm.selectedWorkbenchID = p
        vm.layout.show(.session(s.id))
        await vm.asks.load(projectID: p)
        XCTAssertNil(vm.asks.drawerAskIDs[p], "not measured yet")

        vm.sessionPaneMeasured(s.id, projectID: p, fits: false)
        await vm.asks.load(projectID: p)
        XCTAssertNil(vm.asks.drawerAskIDs[p], "too narrow")

        vm.sessionPaneMeasured(s.id, projectID: p, fits: true)
        XCTAssertEqual(vm.asks.drawerAskIDs[p], askID, "it widened")
        XCTAssertFalse(OwnerAskDrawerLayout.fitsBeside(total: 519))
        XCTAssertTrue(OwnerAskDrawerLayout.fitsBeside(total: 520))
    }

    /// Closing a closed ask looked at from a closed list dismisses nothing.
    func testClosingAClosedAskLeavesTheOpenOnesNew() async throws {
        let (p, s, askID) = try await seed()
        let answer = #"{"verdict":"","answers":[{"id":"a","labels":["No"],"other":""}],"checklist":[],"comments":[],"note":""}"#
        let answered = try await pool.write { d in
            try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s.id, payload: Self.questions, status: "answered", answer: answer)
        }
        let vm = makeVM()
        vm.selectedWorkbenchID = p
        vm.layout.show(.board)
        await vm.asks.load(projectID: p)
        let looked = await vm.asks.lookUp(askID: answered, projectID: p)
        let closed = try XCTUnwrap(looked)
        vm.asks.openDrawer(closed)

        vm.asks.closeDrawer(projectID: p)
        showPane(vm, s.id, project: p)

        XCTAssertEqual(vm.asks.drawerAskIDs[p], askID)
    }

    /// Later/× close the drawer for good: the next poll leaves it closed,
    /// leaving and coming back too; only a new ask opens it again, on the
    /// session's oldest ask ("k of N").
    func testAClosedDrawerStaysClosedUntilANewAskArrives() async throws {
        let (p, s, askID) = try await seed()
        let vm = makeVM()
        vm.selectedWorkbenchID = p
        showPane(vm, s.id, project: p)
        await vm.asks.load(projectID: p)
        XCTAssertEqual(vm.asks.drawerAskIDs[p], askID)

        vm.asks.closeDrawer(projectID: p)
        let unchanged = await vm.asks.refreshIfChanged(projectID: p)
        XCTAssertFalse(unchanged)
        await vm.asks.load(projectID: p)
        showBoard(vm, leaving: s.id)
        showPane(vm, s.id, project: p)
        XCTAssertNil(vm.asks.drawerAskIDs[p], "a closed drawer never re-opens by itself")

        let newer = try await fileAnotherAsk(project: p, sessionID: s.id)
        let changed = await vm.asks.refreshIfChanged(projectID: p)
        XCTAssertTrue(changed)

        XCTAssertEqual(vm.asks.drawerAskIDs[p], askID, "the new ask opens the drawer on the session's first ask")
        XCTAssertEqual(vm.asks.stack(projectID: p).askPosition(of: newer), 2)
    }

    /// A drawer that went because its session left the screen comes back
    /// with it; the closed state lives on the AppState-owned VM.
    func testADrawerHiddenByNavigationComesBackWithItsSession() async throws {
        let (p, s, askID) = try await seed()
        let vm = makeVM()
        vm.selectedWorkbenchID = p
        showPane(vm, s.id, project: p)
        await vm.asks.load(projectID: p)

        showBoard(vm, leaving: s.id)
        XCTAssertNil(vm.asks.drawerAskIDs[p])
        vm.selectedWorkbenchID = nil
        vm.selectedWorkbenchID = p
        showPane(vm, s.id, project: p)

        XCTAssertEqual(vm.asks.drawerAskIDs[p], askID)
    }

    func testAnAnsweredSessionsOtherAsksDoNotPopOverItsTerminal() async throws {
        let (p, s, askID) = try await seed()
        _ = try await fileAnotherAsk(project: p, sessionID: s.id)
        center.start(s, fresh: true)
        let vm = makeVM()
        vm.selectedWorkbenchID = p
        showPane(vm, s.id, project: p)
        let ask = try await openAsk(vm, project: p, id: askID)
        XCTAssertEqual(vm.asks.drawerAskIDs[p], askID)
        pick(vm, askID)

        await vm.asks.answer(ask)

        XCTAssertNil(vm.asks.drawerAskIDs[p], "the terminal takes over; the banner names the other ask")
        XCTAssertEqual(vm.asks.answerNotices[askID], .delivered(.submitted))
    }

    /// Board #501: a Quick ask on screen stays in the banner as one-tap
    /// buttons; the drawer does not open by itself.
    func testAQuickAskOnScreenLeavesTheDrawerClosed() async throws {
        let (p, s, askID) = try await seed()
        try await makeQuick(askID)
        center.start(s, fresh: true)
        let vm = makeVM()
        vm.selectedWorkbenchID = p
        showPane(vm, s.id, project: p)

        await vm.asks.load(projectID: p)
        vm.openNewAsk(projectID: p)

        XCTAssertNil(vm.asks.drawerAsk(projectID: p))
        XCTAssertEqual(vm.asks.stack(projectID: p).asks.map(\.id), [askID], "it waits in the banner and the stack")
    }

    func testAnAskFiledOutsideTheAppNeverOpensByItself() async throws {
        let (p, s, _) = try await seed(session: false)
        let vm = makeVM()
        vm.selectedWorkbenchID = p
        showPane(vm, s.id, project: p)

        await vm.asks.load(projectID: p)

        XCTAssertNil(vm.asks.drawerAskIDs[p])
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

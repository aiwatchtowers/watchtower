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

    private static let questions = #"{"questions":[{"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}]}"#

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "OwnerAsksViewModelTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt asks \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        processes = []
        copied = []
        center = TerminalCenter { [weak self] in
            let process = ProbedInputSession()
            self?.processes.append(process)
            return process
        }
        center.shell = { "/bin/zsh" }
        center.copyToClipboard = { [weak self] in self?.copied.append($0) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM() -> WorkbenchesViewModel {
        WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults, terminalCenter: center)
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
        XCTAssertEqual(vm.asks.drafts.draft(for: askID).picks["a"], .init(labels: ["No"]))
        XCTAssertEqual(vm.asks.drafts.draft(for: askID).note, "Keep the flag off")
        XCTAssertEqual(vm.asks.drawerAskIDs[p], askID)
        vm.asks.stop()
    }

    // MARK: - Answering

    func testAnsweringARunningSessionWritesThenPastesTheLineOnceAndFocusesTheTerminal() async throws {
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

        XCTAssertEqual(delivery, .sent)
        XCTAssertFalse(vm.asks.drawerExpanded, "closed through closeDrawer")
        let stored = try await status(askID)
        XCTAssertEqual(stored.status, "answered")
        XCTAssertEqual(try OwnerAskAnswer.decode(stored.answer).answers, [.init(id: "a", labels: ["Yes"])])
        XCTAssertNotNil(stored.answeredAt.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression),
                        "answered_at is UTC yyyy-MM-ddTHH:mm:ssZ, got \(stored.answeredAt)")
        let line = OwnerAskPrompt.line(id: askID, kind: .question, answer: try OwnerAskAnswer.decode(stored.answer))
        XCTAssertEqual(typed.count, 1, "exactly one paste")
        XCTAssertTrue(String(bytes: typed[0], encoding: .utf8)?.contains(line) == true)
        XCTAssertNil(vm.asks.drawerAskIDs[p], "the drawer closes: the terminal takes over")
        XCTAssertTrue(vm.layout(projectID: p).visiblePanes.contains(.session(s.id)), "the page shows the session")
        XCTAssertNotNil(center.keyboardFocusSerial(for: s.id), "the keyboard moves into it")
        XCTAssertTrue(vm.asks.drafts.draft(for: askID).isEmpty, "the answer is written; the draft goes")
        XCTAssertEqual(vm.asks.openAsks[p], [], "the answered ask leaves the open list")
        XCTAssertEqual(vm.asks.notices[askID]?.text, OwnerAsksViewModel.sentNote)
    }

    /// PROJ-12 (spec 2026-10-03 Part 9, its "PROJ-11"): the answer is
    /// stored before anything is typed, and the typed line is never
    /// followed by Enter.
    func testProj12_TheAnswerIsStoredBeforeTheLineIsTypedAndNeverSubmitted() async throws {
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
        XCTAssertEqual(typed.count, 1)
        XCTAssertFalse(typed[0].contains(0x0D), "the owner presses Return; Watchtower never does")
        XCTAssertFalse(typed[0].contains(0x0A))
    }

    func testCopiedShowsTheClipboardHint() async throws {
        let (p, s, askID) = try await seed()
        center.start(s, fresh: true)
        processes[0].bracketedPasteMode = false
        let vm = makeVM()
        let ask = try await openAsk(vm, project: p, id: askID)
        vm.asks.openDrawer(askID: askID, projectID: p)
        pick(vm, askID)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .copied)
        XCTAssertTrue(typed.isEmpty, "no keystrokes reach the terminal")
        XCTAssertEqual(copied.count, 1)
        XCTAssertTrue(center.clipboardHints.contains(s.id), "the session's pane shows the hint")
        XCTAssertEqual(vm.asks.notices[askID]?.text, WorkbenchCommentsSendBar.copiedNote)
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
        XCTAssertEqual(vm.asks.notices[askID]?.text, OwnerAsksViewModel.noSessionNote)
        XCTAssertEqual(vm.asks.drawerAskIDs[p], askID, "nothing went to a terminal: the drawer stays")
        XCTAssertNil(center.keyboardFocusSerial(for: s.id))
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
        XCTAssertEqual(vm.asks.drafts.draft(for: askID).note, "Ship it", "the draft is kept")
        XCTAssertEqual(vm.asks.notices[askID], .withdrawn)
        XCTAssertEqual(vm.asks.notices[askID]?.text, OwnerAsksViewModel.withdrawnNote)
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

        XCTAssertEqual(results.compactMap { $0 }, [.sent], "one click answers, the other is refused")
        XCTAssertEqual(typed.count, 1)
        XCTAssertEqual(vm.asks.notices[askID], .delivered(.sent), "the second click never reads as withdrawn")
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

    // MARK: - Polling

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

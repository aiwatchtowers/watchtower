import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// What the ask views drive (spec 2026-10-03 Part 8): stack clicks, "k of N ›",
/// notices, closed and withdrawn asks in the drawer, its width, and the
/// answer's draft and error state.
@MainActor
final class OwnerAskViewsTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var center: TerminalCenter!
    private var started = 0

    private static let questions = #"{"questions":[{"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}]}"#

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "OwnerAskViewsTests-\(UUID().uuidString)"))
        started = 0
        center = TerminalCenter { [weak self] in
            self?.started += 1
            return FakeTerminalSession()
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM() -> WorkbenchesViewModel {
        WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults, terminalCenter: center)
    }

    private struct Seeded {
        let project: Int64
        let first: Int64
        let second: Int64
        /// The older ask, of `first`.
        let firstAsk: Int64
        /// The newer ask, of `second`.
        let secondAsk: Int64
    }

    /// A workbench with two shell sessions (never started), each with one
    /// open question ask, the first session's older.
    private func seed() async throws -> Seeded {
        try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, folder: "/tmp/acme")
            let s1 = try TerminalSessionQueries.create(d, .init(projectID: p, kind: .shell, title: "one", folderPath: "/tmp/acme"))
            let s2 = try TerminalSessionQueries.create(d, .init(projectID: p, kind: .shell, title: "two", folderPath: "/tmp/acme"))
            let a1 = try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s1.id, payload: Self.questions,
                                                     createdAt: Self.stamp(minutesAgo: 5))
            let a2 = try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s2.id, payload: Self.questions,
                                                     createdAt: Self.stamp(minutesAgo: 1))
            return Seeded(project: p, first: s1.id, second: s2.id, firstAsk: a1, secondAsk: a2)
        }
    }

    nonisolated private static func stamp(minutesAgo minutes: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-minutes * 60))
    }

    private func shows(_ vm: WorkbenchesViewModel, session: Int64, project: Int64) -> Bool {
        vm.layout(projectID: project).visiblePanes.contains(.session(session))
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

    // MARK: - Stack and "k of N ›"

    func testClickingAStackRowShowsItsSessionAndOpensTheDrawerOnTheAsk() async throws {
        let s = try await seed()
        let vm = makeVM()
        vm.selectedWorkbenchID = s.project
        await vm.asks.load(projectID: s.project)

        await vm.showAsk(s.firstAsk, projectID: s.project)

        XCTAssertEqual(vm.asks.drawerAskIDs[s.project], s.firstAsk)
        XCTAssertEqual(vm.asks.drawerAsk(projectID: s.project)?.sessionID, s.first)
        XCTAssertTrue(shows(vm, session: s.first, project: s.project), "the ask's session goes on screen")
        XCTAssertEqual(started, 0, "a click never starts a stopped session's agent")
    }

    func testNextMovesToTheNextAskAndSwitchesSession() async throws {
        let s = try await seed()
        let vm = makeVM()
        vm.selectedWorkbenchID = s.project
        await vm.asks.load(projectID: s.project)
        await vm.showAsk(s.firstAsk, projectID: s.project)
        let stack = vm.asks.stack(projectID: s.project)
        XCTAssertEqual(stack.askPosition(of: s.firstAsk).map { OwnerAskPresentation.positionLabel($0, of: stack.count) }, "1 of 2")

        await vm.showNextAsk(after: s.firstAsk, projectID: s.project)

        XCTAssertEqual(vm.asks.drawerAskIDs[s.project], s.secondAsk)
        XCTAssertTrue(shows(vm, session: s.second, project: s.project), "the other session's terminal comes on screen")
        XCTAssertFalse(shows(vm, session: s.first, project: s.project))

        await vm.showNextAsk(after: s.secondAsk, projectID: s.project)
        XCTAssertEqual(vm.asks.drawerAskIDs[s.project], s.firstAsk, "past the last it wraps")
    }

    func testAnAskNoticeOpensTheAskOnItsSession() async throws {
        let s = try await seed()
        let vm = makeVM()

        vm.reveal(WorkbenchRoute(projectID: s.project, pane: .terminal, subjectID: s.second, askID: s.secondAsk))

        XCTAssertEqual(vm.selectedWorkbenchID, s.project)
        await waitUntil { vm.asks.drawerAskIDs[s.project] == s.secondAsk && self.shows(vm, session: s.second, project: s.project) }
        XCTAssertEqual(vm.asks.drawerAsk(projectID: s.project)?.id, s.secondAsk, "read although the list was never loaded")
    }

    func testAnAskFiledOutsideTheAppOpensTheDrawerAlone() async throws {
        let s = try await seed()
        let outside = try await pool.write { try TestDatabase.insertOwnerAsk($0, projectID: s.project, payload: Self.questions) }
        let vm = makeVM()

        vm.reveal(WorkbenchRoute(projectID: s.project, pane: .board, askID: outside))

        await waitUntil { vm.asks.drawerAskIDs[s.project] == outside }
        XCTAssertNil(vm.asks.drawerAsk(projectID: s.project)?.sessionID, "the page's own edge hosts it")
    }

    func testANoticeForAnAskGoneMeanwhileStillShowsItsSession() async throws {
        let s = try await seed()
        let vm = makeVM()

        vm.reveal(WorkbenchRoute(projectID: s.project, pane: .terminal, subjectID: s.second, askID: s.secondAsk + 100))

        await waitUntil { self.shows(vm, session: s.second, project: s.project) }
        XCTAssertNil(vm.asks.drawerAskIDs[s.project])
    }

    func testTheDrawerClosesWhenItsSessionLeavesTheScreen() async throws {
        let s = try await seed()
        let vm = makeVM()
        await vm.showAsk(s.firstAsk, projectID: s.project)
        vm.asks.editDraft(s.firstAsk) { $0.note = "half done" }
        XCTAssertEqual(vm.asks.drawerAskIDs[s.project], s.firstAsk)

        await vm.revealTerminal(projectID: s.project, sessionID: s.second)

        XCTAssertFalse(shows(vm, session: s.first, project: s.project))
        XCTAssertNil(vm.asks.drawerAskIDs[s.project], "no drawer, no highlighted row, for a session off screen")
        XCTAssertEqual(vm.asks.drafts.askDraft(for: s.firstAsk).note, "half done", "the draft stays")
    }

    // MARK: - Closed and withdrawn asks

    func testAClosedAskOpensReadOnlyWithItsAnswer() async throws {
        let s = try await seed()
        let answer = #"{"verdict":"","answers":[{"id":"a","labels":["No"],"other":""}],"checklist":[],"comments":[],"note":"later"}"#
        let closed = try await pool.write {
            try TestDatabase.insertOwnerAsk($0, projectID: s.project, sessionID: s.first, payload: Self.questions,
                                            status: "answered", answer: answer)
        }
        let vm = makeVM()
        vm.selectedWorkbenchID = s.project
        await vm.asks.load(projectID: s.project)
        XCTAssertEqual(vm.asks.closedCounts[s.project]?[s.first], 1, "the session row's \"1 closed\"")
        XCTAssertNil(vm.asks.closedCounts[s.project]?[s.second])

        try await pool.write {
            try TestDatabase.insertOwnerAsk($0, projectID: s.project, sessionID: s.first, status: "withdrawn", withdrawnReason: "agent")
        }
        await vm.asks.loadClosed(projectID: s.project, sessionID: s.first)
        XCTAssertEqual(vm.asks.closedCounts[s.project]?[s.first], 2, "the count follows the list it opens")
        let key = OwnerAsksViewModel.ClosedListKey(projectID: s.project, sessionID: s.first)
        XCTAssertEqual(vm.asks.closedLists[key]?.count, 2)
        XCTAssertTrue(vm.asks.closedLists[key]?.contains { $0.id == closed } == true)

        await vm.showAsk(closed, projectID: s.project)
        let shown = try XCTUnwrap(vm.asks.drawerAsk(projectID: s.project))
        XCTAssertFalse(shown.isOpen, "read-only")
        XCTAssertEqual(shown.answer.map(OwnerAskPresentation.answerPicks(from:)), ["a": .init(labels: ["No"])])
        XCTAssertEqual(shown.answer?.note, "later")
        let action = try XCTUnwrap(OwnerAskPresentation.answerActions(for: shown.kind).first)
        XCTAssertFalse(OwnerAskPresentation.canAnswer(shown, draft: vm.asks.drafts.askDraft(for: closed), with: action, answering: false),
                       "a closed ask takes no answer")
    }

    func testWithdrawnAsksCarryTheirReason() async throws {
        let s = try await seed()
        let (old, agent) = try await pool.write { d in
            let old = try TestDatabase.insertOwnerAsk(d, projectID: s.project, sessionID: s.first, kind: "review", docPath: "docs/spec.md",
                                                      status: "withdrawn", withdrawnReason: "superseded")
            try d.execute(sql: "UPDATE owner_asks SET previous_ask_id = ? WHERE id = ?", arguments: [old, s.firstAsk])
            let agent = try TestDatabase.insertOwnerAsk(d, projectID: s.project, sessionID: s.first,
                                                        status: "withdrawn", withdrawnReason: "agent")
            return (old, agent)
        }
        let vm = makeVM()
        await vm.asks.loadClosed(projectID: s.project, sessionID: s.first)
        let list = try XCTUnwrap(vm.asks.closedLists[.init(projectID: s.project, sessionID: s.first)])
        let lines = list.map { OwnerAskPresentation.askStatusLine($0, replacedBy: vm.asks.replacements[s.project]?[$0.id]) }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: zip(list.map(\.id), lines)),
                       [old: "replaced by #\(s.firstAsk)", agent: "withdrawn by the agent"])
    }

    func testAnAskWithdrawnMeanwhileKeepsTheDrawerTheNoticeAndTheDraftUntilDiscarded() async throws {
        let s = try await seed()
        let vm = makeVM()
        vm.selectedWorkbenchID = s.project
        await vm.asks.load(projectID: s.project)
        await vm.showAsk(s.firstAsk, projectID: s.project)
        let ask = try XCTUnwrap(vm.asks.drawerAsk(projectID: s.project))
        vm.asks.editDraft(ask.id) {
            $0.picks["a"] = .init(labels: ["Yes"])
            $0.note = "my reasons"
        }
        try await pool.write {
            try $0.execute(sql: "UPDATE owner_asks SET status = 'withdrawn', withdrawn_reason = 'agent' WHERE id = ?",
                           arguments: [ask.id])
        }

        let refused = await vm.asks.answer(ask)
        XCTAssertNil(refused)

        XCTAssertEqual(vm.asks.answerNotices[ask.id], .withdrawn)
        let shown = try XCTUnwrap(vm.asks.drawerAsk(projectID: s.project), "the drawer still shows it")
        XCTAssertEqual(shown.status, .withdrawn)
        XCTAssertEqual(OwnerAskPresentation.askStatusLine(shown, replacedBy: nil), "withdrawn by the agent")
        XCTAssertEqual(vm.asks.drafts.askDraft(for: ask.id).note, "my reasons", "the draft is kept")
        XCTAssertEqual(vm.asks.drafts.count, 1)

        // "Discard draft"
        vm.asks.drafts.discard(ask.id)
        XCTAssertEqual(vm.asks.drafts.count, 0)
    }

    // MARK: - Drawer

    func testTheDrawerWidthIsPersisted() async throws {
        let vm = makeVM()
        XCTAssertEqual(vm.asks.drawerWidth, OwnerAsksViewModel.defaultDrawerWidth)
        vm.asks.setDrawerWidth(512)
        XCTAssertEqual(defaults.double(forKey: "workbench.asks.drawerWidth"), 512)
        XCTAssertEqual(makeVM().asks.drawerWidth, 512, "a relaunch keeps it")
        vm.asks.setDrawerWidth(10)
        XCTAssertEqual(vm.asks.drawerWidth, OwnerAsksViewModel.drawerWidthRange.lowerBound)
    }

    func testClosingTheDrawerKeepsTheDraftAndEndsExpand() async throws {
        let s = try await seed()
        let vm = makeVM()
        await vm.showAsk(s.firstAsk, projectID: s.project)
        vm.asks.editDraft(s.firstAsk) { $0.note = "half done" }
        vm.asks.drawerExpanded = true

        vm.asks.closeDrawer(projectID: s.project)  // "Later"

        XCTAssertNil(vm.asks.drawerAsk(projectID: s.project))
        XCTAssertFalse(vm.asks.drawerExpanded)
        XCTAssertEqual(vm.asks.drafts.askDraft(for: s.firstAsk).note, "half done")
    }

    func testAnExpandedDrawerObscuresItsSessionsTerminal() async throws {
        let s = try await seed()
        let vm = makeVM()
        await vm.showAsk(s.firstAsk, projectID: s.project)
        XCTAssertFalse(vm.isObscured(sessionID: s.first, projectID: s.project), "beside the terminal, not over it")

        vm.asks.drawerExpanded = true

        XCTAssertTrue(vm.isObscured(sessionID: s.first, projectID: s.project))
        XCTAssertFalse(vm.isObscured(sessionID: s.second, projectID: s.project), "another session's terminal is not under it")
        vm.asks.closeDrawer(projectID: s.project)
        XCTAssertFalse(vm.isObscured(sessionID: s.first, projectID: s.project))
    }

    func testAnExpandedOutsideTheAppDrawerObscuresEveryTerminalOfThePage() async throws {
        let s = try await seed()
        let outside = try await pool.write { try TestDatabase.insertOwnerAsk($0, projectID: s.project, payload: Self.questions) }
        let vm = makeVM()
        await vm.showAsk(outside, projectID: s.project)
        vm.asks.drawerExpanded = true
        XCTAssertTrue(vm.isObscured(sessionID: s.first, projectID: s.project))
        XCTAssertTrue(vm.isObscured(sessionID: s.second, projectID: s.project))
    }

    /// The go-to palette's choice: picking the session under an expanded
    /// drawer collapses the drawer, then gives the terminal the keyboard.
    func testGoToASessionUnderAnExpandedDrawerCollapsesItFirst() async throws {
        let s = try await seed()
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: s.project)
        await vm.showSession(id: s.first)
        await vm.showAsk(s.firstAsk, projectID: s.project)
        vm.asks.drawerExpanded = true
        let session = try XCTUnwrap(vm.session(s.first, projectID: s.project))
        let workbench = try XCTUnwrap(vm.selectedWorkbench)

        await vm.goTo(.session(session, workbench: workbench))

        XCTAssertFalse(vm.asks.drawerExpanded)
        XCTAssertFalse(vm.isObscured(sessionID: s.first, projectID: s.project))
        XCTAssertEqual(center.keyboardFocusRequest?.sessionID, s.first)
        XCTAssertEqual(vm.asks.drawerAskIDs[s.project], s.firstAsk, "the drawer stays, beside the terminal")
    }

    // MARK: - Answering

    func testDraftEditsAreRefusedWhileTheAnswerIsWritten() async throws {
        let s = try await seed()
        let vm = makeVM()
        await vm.asks.load(projectID: s.project)
        let ask = try XCTUnwrap(vm.asks.openAsks[s.project]?.first { $0.id == s.firstAsk })
        vm.asks.editDraft(ask.id) { $0.picks["a"] = .init(labels: ["Yes"]) }
        // Holds the writer, so the answer's write waits mid-flight.
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let pool = try XCTUnwrap(self.pool)
        DispatchQueue.global().async {
            try? pool.write { _ in
                held.signal()
                release.wait()
            }
        }
        held.wait()

        let answering = Task { await vm.asks.answer(ask) }
        await waitUntil { vm.asks.answering.contains(ask.id) }
        let accepted = vm.asks.editDraft(ask.id) { $0.note = "typed during the write" }
        release.signal()
        let delivery = await answering.value

        XCTAssertFalse(accepted, "an edit the write would not carry is refused")
        XCTAssertEqual(delivery, .noSession, "the session never ran: the brief delivers it")
        let stored = try await pool.read { try OwnerAskQueries.ask($0, id: ask.id, projectID: s.project) }
        XCTAssertEqual(stored?.answer?.note, "")
        XCTAssertTrue(vm.asks.editDraft(ask.id) { $0.note = "after" }, "edits are taken again once it is done")
    }

    func testAFailedAnswerSurvivesAGoodReload() async throws {
        let s = try await seed()
        let vm = makeVM()
        await vm.asks.load(projectID: s.project)
        let ask = try XCTUnwrap(vm.asks.openAsks[s.project]?.first { $0.id == s.firstAsk })
        vm.asks.editDraft(ask.id) { $0.picks["a"] = .init(labels: ["Yes"]) }
        try await pool.write {
            try $0.execute(sql: "CREATE TRIGGER no_answers BEFORE UPDATE ON owner_asks BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        }

        let refused = await vm.asks.answer(ask)
        XCTAssertNil(refused)
        XCTAssertNotNil(vm.asks.answerErrors[ask.id])
        await vm.asks.load(projectID: s.project)
        XCTAssertNil(vm.asks.loadErrors[s.project])
        XCTAssertNotNil(vm.asks.answerErrors[ask.id], "a good reload does not hide the failed answer")
        XCTAssertFalse(vm.asks.drafts.askDraft(for: ask.id).isEmpty, "the draft is kept")

        try await pool.write { try $0.execute(sql: "DROP TRIGGER no_answers") }
        let saved = await vm.asks.answer(ask)
        XCTAssertNotNil(saved)
        XCTAssertNil(vm.asks.answerErrors[ask.id], "the answer that saves clears it")
    }

    func testAFailedChangeCheckIsReported() async throws {
        let s = try await seed()
        let vm = makeVM()
        try await pool.write { try $0.execute(sql: "DROP TABLE owner_asks") }

        let reloaded = await vm.asks.refreshIfChanged(projectID: s.project)

        XCTAssertFalse(reloaded)
        XCTAssertNotNil(vm.asks.loadErrors[s.project], "an empty stack with no word would read as nothing waiting")
    }
}

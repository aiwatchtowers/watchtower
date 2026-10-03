import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Records what the report's links asked for.
@MainActor
private final class ReportActionLog {
    var asks: [Int64] = []
    var targets: [Int64] = []
    var urls: [URL] = []

    var actions: SessionReportActions {
        SessionReportActions(
            openAsk: { [weak self] in self?.asks.append($0) },
            openTarget: { [weak self] in self?.targets.append($0) },
            openURL: { [weak self] in self?.urls.append($0) }
        )
    }
}

@MainActor
private final class RemoteReads {
    var count = 0
    var remote: String? = "git@github.com:acme/app.git" // leak-check:allow
}

/// The Session view (spec 2026-10-03-workbench-session-report Part 7): its
/// placement, what it shows and what its links do. View-model and view
/// inspection tests only (no snapshots); the strings are
/// `SessionReportPresentationTests`'.
@MainActor
final class WorkbenchSessionReportViewTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var terminals: TerminalCenter!
    private var centers: [SessionReportCenter] = []

    private static let questions = #"{"questions":[{"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}]}"#
    private static let repository = URL(string: "https://github.com/acme/app/pull/147")

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchSessionReportViewTests-\(UUID().uuidString)"))
        terminals = TerminalCenter { FakeTerminalSession() }
        centers = []
    }

    override func tearDown() {
        centers.forEach { $0.stop() }
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM() -> WorkbenchesViewModel {
        WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                             terminalCenter: terminals)
    }

    private struct Seeded {
        let project: Workbench
        let first: TerminalSession
        let second: TerminalSession
        let shell: TerminalSession
    }

    /// A workbench with two `claude` sessions and a shell, none started.
    private func seed() async throws -> Seeded {
        try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, folder: "/tmp/acme")
            let claude = { (title: String) in
                try TerminalSessionQueries.create(d, .init(projectID: p, kind: .claude, title: title, folderPath: "/tmp/acme",
                                                           claudeSessionID: UUID().uuidString))
            }
            let first = try claude("one")
            let second = try claude("two")
            let shell = try TerminalSessionQueries.create(d, .init(projectID: p, kind: .shell, title: "zsh", folderPath: "/tmp/acme"))
            let project = try XCTUnwrap(try Workbench.fetchOne(d, sql: "SELECT * FROM projects WHERE id = ?", arguments: [p]))
            return Seeded(project: project, first: first, second: second, shell: shell)
        }
    }

    /// `first` and `second` side by side.
    private static func split(_ first: WorkspacePane, _ second: WorkspacePane) -> WorkspaceLayout {
        var layout = WorkspaceLayout.default
        layout.show(first)
        layout.split(with: second)
        return layout
    }

    private static func report(_ json: String) throws -> SessionReport {
        try JSONDecoder().decode(SessionReport.self, from: Data(json.utf8))
    }

    private static let full = #"""
    {"session": {"id": 7, "title": "Release", "target_id": 314, "finish_summary": "Shipped the sheet.", "finished_at": "2026-10-02T12:00:00Z"},
     "progress": {"done": 14, "total": 15},
     "on_you": [{"id": 12, "kind": "question", "title": "Which flag?"}],
     "now": [{"id": 273, "text": "Export UI", "status": "in_progress", "branch": "feat/export-ui"}],
     "phases": [{"target_id": 300, "text": "Export", "done": 7, "total": 7}],
     "next": [{"id": 423, "text": "Document the export", "status": "todo"}],
     "prs": [{"ref": "pr:147", "pr_number": 147, "title": "Export sheet", "state": "open"},
             {"ref": "branch:feat/side", "state": "unknown"}]}
    """#

    private func content(
        _ report: SessionReport,
        staleError: String? = nil,
        log: ReportActionLog,
        url: @escaping (SessionReport.PullRequest) -> URL? = { _ in nil }
    ) -> SessionReportContent {
        SessionReportContent(report: report, state: .notStarted, staleError: staleError, pullRequestURL: url,
                             actions: log.actions)
    }

    // MARK: - Placement

    /// The Session view tracks the selected session: a panel click (or the
    /// header switcher, ⌘1…⌘9) puts the session beside it and the report
    /// switches to that session.
    func testTheSessionViewFollowsTheSelectedSession() async throws {
        let s = try await seed()
        let vm = makeVM()
        vm.selectedWorkbenchID = s.project.id
        await vm.loadSessions(projectID: s.project.id)
        vm.setLayout(Self.split(.session(s.first.id), .sessionReport(s.first.id)), projectID: s.project.id)

        await vm.showSession(id: s.second.id)

        XCTAssertEqual(vm.layout(projectID: s.project.id).visiblePanes, [.session(s.second.id), .sessionReport(s.second.id)])
        guard case let .loading(row) = vm.reportPane(sessionID: s.second.id, projectID: s.project.id) else {
            return XCTFail("the second session's report is loading")
        }
        XCTAssertEqual(row.id, s.second.id)
    }

    func testWithNoSessionTheViewSaysPickASession() async throws {
        let s = try await seed()
        let vm = makeVM()
        await vm.loadSessions(projectID: s.project.id)
        XCTAssertEqual(vm.reportPane(sessionID: 999, projectID: s.project.id), .pickSession, "a deleted session")
        XCTAssertEqual(vm.reportPane(sessionID: s.shell.id, projectID: s.project.id), .pickSession, "a shell has no report")
        XCTAssertEqual(SessionReportPresentation.noSessionText, "Pick a session")
    }

    /// `showView(.report)` (the header's Session button, plan Task 11): the
    /// report of the session on screen, beside its terminal. No session →
    /// nothing changes.
    func testShowingTheSessionViewPutsTheReportBesideTheTerminal() async throws {
        let s = try await seed()
        let vm = makeVM()
        await vm.loadSessions(projectID: s.project.id)
        vm.setLayout(Self.split(.session(s.first.id), .board),
                     projectID: s.project.id)
        await vm.showView(.report, project: s.project)
        XCTAssertEqual(vm.layout(projectID: s.project.id).visiblePanes, [.session(s.first.id), .sessionReport(s.first.id)])

        let empty = try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, name: "empty", folder: "/tmp/empty")
            return try XCTUnwrap(try Workbench.fetchOne(d, sql: "SELECT * FROM projects WHERE id = ?", arguments: [p]))
        }
        await vm.loadSessions(projectID: empty.id)
        await vm.showView(.report, project: empty)
        XCTAssertEqual(vm.layout(projectID: empty.id), .default)
    }

    /// From a single pane the Session button opens the terminal and its
    /// report side by side (board #357), so the report then follows panel
    /// clicks instead of giving way to the terminal.
    func testFromASinglePaneTheSessionButtonOpensTheTerminalAndItsReport() async throws {
        let s = try await seed()
        let vm = makeVM()
        vm.selectedWorkbenchID = s.project.id
        await vm.loadSessions(projectID: s.project.id)
        let p = s.project.id
        var single = WorkspaceLayout.default
        single.show(.session(s.first.id))
        vm.setLayout(single, projectID: p)

        await vm.showView(.report, project: s.project)
        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [.session(s.first.id), .sessionReport(s.first.id)])

        await vm.showSession(id: s.second.id)
        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [.session(s.second.id), .sessionReport(s.second.id)],
                       "a panel click re-points the report")
    }

    /// With no terminal on screen (a lone Board, or Board | Files), the
    /// Session button still pairs the report with its session's terminal.
    func testWithNoTerminalOnScreenTheSessionButtonPairsTheReportWithItsSession() async throws {
        let s = try await seed()
        let vm = makeVM()
        await vm.loadSessions(projectID: s.project.id)
        let p = s.project.id
        let first = try XCTUnwrap(vm.orderedSessions(projectID: p).first { $0.kind == .claude }).id

        vm.setLayout(.default, projectID: p)
        await vm.showView(.report, project: s.project)
        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [.session(first), .sessionReport(first)])

        vm.setLayout(Self.split(.board, .files), projectID: p)
        await vm.showView(.report, project: s.project)
        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [.session(first), .sessionReport(first)])
    }

    /// On screen, the center runs and refreshes that session's report; off
    /// screen it stops. A pane with no `claude` session runs nothing.
    func testTheCenterRunsTheReportWhileTheViewIsOnScreen() async throws {
        let s = try await seed()
        let center = SessionReportCenter(runner: FakeCLIRunner(stdout: Data(#"{"session": {"id": 1}}"#.utf8)))
        centers.append(center)
        let vm = makeVM()
        vm.sessionReports = center
        await vm.loadSessions(projectID: s.project.id)

        vm.reportAppeared(sessionID: s.shell.id, projectID: s.project.id)
        XCTAssertNil(center.shown)
        vm.reportAppeared(sessionID: s.first.id, projectID: s.project.id)
        XCTAssertEqual(center.shown, .init(session: s.first.id, workbench: s.project.id))
        vm.reportDisappeared(sessionID: s.first.id)
        XCTAssertNil(center.shown)
    }

    /// The reported session deleted while its Session view stays on screen:
    /// the center stops running its report; the row read later runs it.
    func testADeletedSessionStopsItsReportRuns() async throws {
        let s = try await seed()
        let center = SessionReportCenter(runner: FakeCLIRunner(stdout: Data(#"{"session": {"id": 1}}"#.utf8)))
        centers.append(center)
        let vm = makeVM()
        vm.sessionReports = center

        vm.reportSessionChanged(sessionID: s.first.id, projectID: s.project.id)
        XCTAssertNil(center.shown, "the list is not read yet")
        await vm.loadSessions(projectID: s.project.id)
        vm.reportSessionChanged(sessionID: s.first.id, projectID: s.project.id)
        XCTAssertEqual(center.shown, .init(session: s.first.id, workbench: s.project.id))

        try await pool.write { try $0.execute(sql: "DELETE FROM terminal_sessions WHERE id = ?", arguments: [s.first.id]) }
        await vm.loadSessions(projectID: s.project.id)
        vm.reportSessionChanged(sessionID: s.first.id, projectID: s.project.id)
        XCTAssertNil(center.shown)
        XCTAssertFalse(center.isPollingReport)
    }

    /// A session switch re-points the pane: the new view appears (its own
    /// `.id`), and the old one's late disappear leaves the new one shown.
    func testASessionSwitchShowsTheNewSessionsReport() async throws {
        let s = try await seed()
        let center = SessionReportCenter(runner: FakeCLIRunner(stdout: Data(#"{"session": {"id": 1}}"#.utf8)))
        centers.append(center)
        let vm = makeVM()
        vm.sessionReports = center
        await vm.loadSessions(projectID: s.project.id)

        vm.reportAppeared(sessionID: s.first.id, projectID: s.project.id)
        vm.reportAppeared(sessionID: s.second.id, projectID: s.project.id)
        vm.reportDisappeared(sessionID: s.first.id)
        XCTAssertEqual(center.shown, .init(session: s.second.id, workbench: s.project.id))
        XCTAssertTrue(center.isPollingReport)
    }

    /// The panel's rows coming on screen run that workbench's summary.
    func testTheSessionRowsAppearingRunTheSummary() async throws {
        let s = try await seed()
        let runner = FakeCLIRunner(stdout: Data(#"[{"session_id": 1, "done": 1, "total": 2}]"#.utf8))
        let center = SessionReportCenter(runner: runner)
        centers.append(center)
        let vm = makeVM()
        vm.sessionReports = center

        await vm.sessionRowsAppeared(projectID: s.project.id)

        XCTAssertNotNil(vm.terminalSessions[s.project.id], "the list loads")
        let deadline = Date().addingTimeInterval(5)
        while center.summaries[s.project.id]?.value == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(center.summaries[s.project.id]?.value)
        XCTAssertTrue(runner.invocations.contains {
            $0 == ["workbench", "session-report", "--workbench", String(s.project.id), "--summary", "--json"]
        })
    }

    // MARK: - States

    func testThePaneStates() async throws {
        let s = try await seed()
        let report = try Self.report(Self.full)
        XCTAssertEqual(WorkbenchesViewModel.reportPane(session: nil, snapshot: .init(value: report)), .pickSession)
        XCTAssertEqual(WorkbenchesViewModel.reportPane(session: s.first, snapshot: nil), .loading(s.first))
        XCTAssertEqual(WorkbenchesViewModel.reportPane(session: s.first, snapshot: .init(value: nil, error: "boom")),
                       .failed(s.first, error: "boom"))
        XCTAssertEqual(WorkbenchesViewModel.reportPane(session: s.first, snapshot: .init(value: report)),
                       .report(s.first, report, staleError: nil))
        XCTAssertEqual(WorkbenchesViewModel.reportPane(session: s.first, snapshot: .init(value: report, error: "busy")),
                       .report(s.first, report, staleError: "busy"), "a failed refresh keeps the last report")
    }

    func testAStaleReportShowsItsErrorLine() throws {
        let log = ReportActionLog()
        let view = content(try Self.report(Self.full), staleError: "watchtower exited with error: busy", log: log)
        XCTAssertNoThrow(try view.inspect().find(text: "watchtower exited with error: busy"))
        XCTAssertNoThrow(try view.inspect().find(text: "14 / 15 tasks"), "the last report stays under it")
        XCTAssertThrowsError(try content(try Self.report(Self.full), log: log).inspect()
            .find(text: "watchtower exited with error: busy"))
    }

    func testTheEmptyStates() throws {
        let view = content(try Self.report(#"{"session": {"id": 7, "title": "Release"}}"#), log: ReportActionLog())
        for text in [
            SessionReportPresentation.onYouEmptyText,
            SessionReportPresentation.nowEmptyText,
            SessionReportPresentation.prsEmptyText,
            SessionReportPresentation.phasesEmptyText,
            SessionReportPresentation.lastWordEmptyText
        ] {
            XCTAssertNoThrow(try view.inspect().find(text: text), text)
        }
    }

    func testTheSectionsComeInThePartOneOrder() throws {
        let view = content(try Self.report(Self.full), log: ReportActionLog())
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        let order = ["14 / 15 tasks", "On you", "Now", "Pull requests", "Done", "Agent's last word"]
        let indices = try order.map { title in try XCTUnwrap(texts.firstIndex(of: title), title) }
        XCTAssertEqual(indices, indices.sorted())
        XCTAssertNoThrow(try view.inspect().find(text: "Shipped the sheet."))
    }

    // MARK: - Links

    /// **Open** on an ask opens the asks drawer on that ask, beside its
    /// session's terminal; the Session view stays beside it.
    func testOpenOnAnAskOpensTheDrawerOnThatAsk() async throws {
        let log = ReportActionLog()
        try content(try Self.report(Self.full), log: log).inspect().find(button: "Open").tap()
        XCTAssertEqual(log.asks, [12])

        let s = try await seed()
        let ask = try await pool.write {
            try TestDatabase.insertOwnerAsk($0, projectID: s.project.id, sessionID: s.first.id, payload: Self.questions)
        }
        let vm = makeVM()
        vm.selectedWorkbenchID = s.project.id
        await vm.loadSessions(projectID: s.project.id)
        await vm.asks.load(projectID: s.project.id)
        vm.setLayout(Self.split(.session(s.first.id), .sessionReport(s.first.id)), projectID: s.project.id)

        await vm.showAsk(ask, projectID: s.project.id)

        XCTAssertEqual(vm.asks.drawerAskIDs[s.project.id], ask)
        XCTAssertEqual(vm.layout(projectID: s.project.id).visiblePanes, [.session(s.first.id), .sessionReport(s.first.id)])
    }

    func testAPullRequestRowWithAURLOpensItAndOneWithoutIsNotALink() throws {
        let log = ReportActionLog()
        let url = try XCTUnwrap(Self.repository)
        let view = content(try Self.report(Self.full), log: log) { $0.prNumber == 147 ? url : nil }
        try view.inspect().find(button: "PR #147 Export sheet").tap()
        XCTAssertEqual(log.urls, [url])
        XCTAssertThrowsError(try view.inspect().find(button: "feat/side"), "a branch with no PR is not a link")
        XCTAssertNoThrow(try view.inspect().find(text: "feat/side"))

        let unknown = content(try Self.report(Self.full), log: log)
        XCTAssertThrowsError(try unknown.inspect().find(button: "PR #147 Export sheet"), "an unknown remote: no link")
        XCTAssertNoThrow(try unknown.inspect().find(text: "PR #147 Export sheet"))
    }

    /// The PR URL comes from the folder's `origin` remote, read once per
    /// workbench; a remote not on GitHub gives no URL.
    func testThePullRequestURLComesFromTheOriginRemote() async throws {
        let s = try await seed()
        let report = try Self.report(Self.full)
        let vm = makeVM()
        let reads = RemoteReads()
        vm.readOriginRemote = { _ in
            reads.count += 1
            return reads.remote
        }
        XCTAssertNil(vm.pullRequestURL(report.prs[0], projectID: s.project.id), "not read yet")

        await vm.loadGitHubRepository(project: s.project)
        await vm.loadGitHubRepository(project: s.project)
        XCTAssertEqual(vm.pullRequestURL(report.prs[0], projectID: s.project.id), Self.repository)
        XCTAssertNil(vm.pullRequestURL(report.prs[1], projectID: s.project.id), "a branch has no PR page")
        XCTAssertEqual(reads.count, 1, "read once per workbench")

        reads.remote = "git@gitlab.com:acme/app.git" // leak-check:allow
        let other = try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, name: "other", folder: "/tmp/other")
            return try XCTUnwrap(try Workbench.fetchOne(d, sql: "SELECT * FROM projects WHERE id = ?", arguments: [p]))
        }
        await vm.loadGitHubRepository(project: other)
        XCTAssertNil(vm.pullRequestURL(report.prs[0], projectID: other.id))
    }

    /// A target id opens the Board (beside the terminal) on that target.
    func testATargetIDOpensTheBoardOnIt() async throws {
        let log = ReportActionLog()
        let view = content(try Self.report(Self.full), log: log)
        try view.inspect().find(button: "#273").tap()
        try view.inspect().find(button: "Next: #423 Document the export").tap()
        XCTAssertEqual(log.targets, [273, 423])

        let s = try await seed()
        let vm = makeVM()
        vm.setLayout(Self.split(.session(s.first.id), .sessionReport(s.first.id)), projectID: s.project.id)
        vm.showTargetOnBoard(314, projectID: s.project.id)
        XCTAssertEqual(vm.layout(projectID: s.project.id).visiblePanes, [.session(s.first.id), .board])
        XCTAssertEqual(vm.boardFocus[s.project.id], 314)
        XCTAssertEqual(vm.takeBoardFocus(projectID: s.project.id), 314)
        XCTAssertNil(vm.takeBoardFocus(projectID: s.project.id), "taken once")
    }
}

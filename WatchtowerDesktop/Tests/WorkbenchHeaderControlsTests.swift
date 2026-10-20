import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The workbench row's `[Session | Board | Files] … ⚡ ▥ ◫ ⋯` (spec
/// 2026-10-20-workbench-header §1, calls 2 and 7): the tabs, the Session
/// tab's lit rule, Analytics and split as icons, the ⚡ menu's New
/// Automation… and the ⋯ menu's actions.
@MainActor
final class WorkbenchHeaderControlsTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var center: TerminalCenter!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchHeaderControlsTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt controls \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        center = TerminalCenter { FakeTerminalSession(pid: 0) }
        center.shell = { "/bin/zsh" }
        center.transcriptExists = { _ in true }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM(_ runner: FakeCLIRunner = FakeCLIRunner()) -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults,
                                      terminalCenter: center)
        vm.titleService = { _ in .init(title: "", written: false) }
        return vm
    }

    private struct Seeded {
        let project: Workbench
        let first: TerminalSession
        let second: TerminalSession
    }

    /// A workbench on a real folder with two `claude` sessions, none started.
    private func seed() async throws -> Seeded {
        let dir = folder.path
        return try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, folder: dir)
            let claude = { (title: String) in
                try TerminalSessionQueries.create(d, .init(projectID: p, kind: .claude, title: title, folderPath: dir,
                                                           claudeSessionID: UUID().uuidString.lowercased()))
            }
            let first = try claude("one")
            let second = try claude("two")
            let project = try XCTUnwrap(try Workbench.fetchOne(d, sql: "SELECT * FROM projects WHERE id = ?", arguments: [p]))
            return Seeded(project: project, first: first, second: second)
        }
    }

    /// `first` and `second` side by side.
    private static func split(_ first: WorkspacePane, _ second: WorkspacePane) -> WorkspaceLayout {
        var layout = WorkspaceLayout.default
        layout.show(first)
        layout.split(with: second)
        return layout
    }

    private func controls(
        _ vm: WorkbenchesViewModel,
        _ project: Workbench,
        automations: WorkbenchAutomationsMenu? = nil,
        onCleanUp: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {}
    ) -> WorkbenchHeaderControls {
        WorkbenchHeaderControls(vm: vm, project: project, automations: automations, onDelete: onDelete,
                                onCleanUpOldWorktrees: onCleanUp)
    }

    private static func title(_ toggle: InspectableView<ViewType.Toggle>) throws -> String {
        try toggle.labelView().label().title().text().string()
    }

    /// The tab capsule's toggle titled `title`, read off a fresh body (each
    /// body captures the layout it was drawn for).
    private func toggle(_ title: String, _ sut: WorkbenchHeaderControls) throws -> InspectableView<ViewType.Toggle> {
        try sut.inspect().find(ViewType.Toggle.self) { try Self.title($0) == title }
    }

    /// The icon button whose help is `help` (ViewInspector reads a Button's
    /// help, not its accessibility label, on this SDK).
    private func button(help: String, _ sut: WorkbenchHeaderControls) throws -> InspectableView<ViewType.Button> {
        try sut.inspect().find(ViewType.Button.self) { try $0.help().string() == help }
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

    private static let analyticsHelp = "Agent time, cost and hints for this workbench"

    // MARK: - View tabs

    /// The tab capsule holds exactly Session | Board | Files (spec
    /// 2026-10-20 §1): Terminal, Workchat, Report and Changes moved to the
    /// session strip, Analytics is an icon. The ⋯ menu's archive choices are
    /// plain-titled toggles, not tabs.
    func testTheViewTabsReadSessionBoardFiles() async throws {
        let s = try await seed()
        let sut = controls(makeVM(), s.project)

        let titles = try sut.inspect().findAll(ViewType.Toggle.self).compactMap { try? Self.title($0) }
        XCTAssertEqual(titles, ["Session", "Board", "Files"])
        XCTAssertThrowsError(try sut.inspect().find(WorkbenchSessionsMenu.self), "the sessions menu is the strip's")
    }

    /// Analytics is an icon button: in a split it shows the Analytics view
    /// beside the session, and a second click closes it again.
    func testAnalyticsIsAnIconToggle() async throws {
        let s = try await seed()
        let vm = makeVM()
        vm.selectedWorkbenchID = s.project.id
        await vm.loadSessions(projectID: s.project.id)
        let p = s.project.id
        let terminal = WorkspacePane.session(s.first.id)
        vm.setLayout(Self.split(terminal, .board), projectID: p)
        let panes = { vm.layout(projectID: p).visiblePanes }

        try button(help: Self.analyticsHelp, controls(vm, s.project)).tap()
        await waitUntil { panes() == [terminal, .analytics] }
        try button(help: Self.analyticsHelp, controls(vm, s.project)).tap()
        XCTAssertEqual(panes(), [terminal], "off closes the Analytics pane, the session stays")
    }

    /// Call 7: Session is lit while any pane shows a session view. In a
    /// split, off leaves the other pane alone; on a single pane the tabs
    /// pick — an unlit Session shows a session in its remembered mode, the
    /// lit one does nothing.
    func testSessionTabFollowsTheLitRule() async throws {
        let s = try await seed()
        let vm = makeVM()
        vm.selectedWorkbenchID = s.project.id
        await vm.loadSessions(projectID: s.project.id)
        let p = s.project.id
        let layout = { vm.layout(projectID: p) }

        vm.setLayout(Self.split(.session(s.first.id), .board), projectID: p)
        XCTAssertTrue(try toggle("Session", controls(vm, s.project)).isOn())
        XCTAssertTrue(try toggle("Board", controls(vm, s.project)).isOn())
        try toggle("Session", controls(vm, s.project)).tap()
        XCTAssertEqual(layout().visiblePanes, [.board])
        XCTAssertFalse(layout().isSplit)

        XCTAssertFalse(try toggle("Session", controls(vm, s.project)).isOn())
        try toggle("Session", controls(vm, s.project)).tap()
        await waitUntil { layout().isShowingSessionView }
        XCTAssertFalse(layout().isSplit, "a single pane is replaced")
        XCTAssertFalse(layout().isShowing(.board))

        let single = layout()
        XCTAssertTrue(try toggle("Session", controls(vm, s.project)).isOn())
        try toggle("Session", controls(vm, s.project)).tap()
        XCTAssertEqual(layout().visiblePanes, single.visiblePanes, "the lit tab never empties the page")

        // A session last shown in Workchat comes back in Workchat.
        var board = WorkspaceLayout.default
        board.workchatSessions = [s.first.id, s.second.id]
        vm.setLayout(board, projectID: p)
        try toggle("Session", controls(vm, s.project)).tap()
        await waitUntil { layout().isShowingSessionView }
        XCTAssertEqual(layout().visiblePanes.count, 1)
        XCTAssertTrue(layout().visiblePanes[0].isWorkchat, "the remembered mode: \(layout().visiblePanes)")
    }

    /// Call 7 in a split of two non-session views: Session on shows the
    /// session beside the first pane, in its remembered mode — the
    /// terminal or the Workchat — and never replaces both panes.
    func testSessionTabInABoardFilesSplitKeepsTheFirstPane() async throws {
        let s = try await seed()
        let vm = makeVM()
        vm.selectedWorkbenchID = s.project.id
        await vm.loadSessions(projectID: s.project.id)
        let p = s.project.id
        let panes = { vm.layout(projectID: p).visiblePanes }
        let isTerminal = { (pane: WorkspacePane) in if case .session = pane { true } else { false } }

        vm.setLayout(Self.split(.board, .files), projectID: p)
        try toggle("Session", controls(vm, s.project)).tap()
        await waitUntil { panes().count == 2 && isTerminal(panes()[1]) }
        XCTAssertEqual(panes().first, .board, "terminal mode: \(panes())")

        var chat = Self.split(.board, .files)
        chat.workchatSessions = [s.first.id, s.second.id]
        vm.setLayout(chat, projectID: p)
        try toggle("Session", controls(vm, s.project)).tap()
        await waitUntil { panes().count == 2 && panes()[1].isWorkchat }
        XCTAssertEqual(panes().first, .board, "Workchat mode: \(panes())")
    }

    /// With no session, Session is not disabled: it runs today's Terminal
    /// path (`showView(.terminal)`), which opens the most recent session —
    /// here a new one, as there is none.
    func testSessionTabWithNoSessionDoesWhatTerminalDid() async throws {
        let dir = folder.appendingPathComponent("empty", isDirectory: true).path
        let empty = try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, name: "empty", folder: dir)
            return try XCTUnwrap(try Workbench.fetchOne(d, sql: "SELECT * FROM projects WHERE id = ?", arguments: [p]))
        }
        let vm = makeVM()
        vm.selectedWorkbenchID = empty.id
        await vm.loadSessions(projectID: empty.id)
        XCTAssertNil(vm.sessionViewTarget(projectID: empty.id))
        let session = try toggle("Session", controls(vm, empty))
        XCTAssertFalse(try session.isDisabled())
        XCTAssertFalse(try session.isOn())

        try session.tap()
        await waitUntil { vm.layout(projectID: empty.id).isShowingSessionView }
        let rows = try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: empty.id) }
        XCTAssertEqual(rows.count, 1, "Terminal's path with none: the most recent session, here a new one")
    }

    /// Board and Files toggle their views as before: on puts the view
    /// beside the session in a split, off closes that pane.
    func testBoardAndFilesToggleTheirViews() async throws {
        let s = try await seed()
        let vm = makeVM()
        vm.selectedWorkbenchID = s.project.id
        await vm.loadSessions(projectID: s.project.id)
        let p = s.project.id
        let terminal = WorkspacePane.session(s.first.id)
        vm.setLayout(Self.split(terminal, .board), projectID: p)
        let panes = { vm.layout(projectID: p).visiblePanes }

        try toggle("Files", controls(vm, s.project)).tap()
        await waitUntil { panes() == [terminal, .files] }
        XCTAssertFalse(try toggle("Board", controls(vm, s.project)).isOn())
        try toggle("Board", controls(vm, s.project)).tap()
        await waitUntil { panes() == [terminal, .board] }
        try toggle("Board", controls(vm, s.project)).tap()
        XCTAssertEqual(panes(), [terminal])
    }

    // MARK: - Split

    /// The split button splits the pane, and then reads as its way back to
    /// one pane (#562 restyled it; its label and help still flip).
    func testTheSplitButtonSplitsAndThenOffersOnePane() async throws {
        let s = try await seed()
        let vm = makeVM()
        vm.selectedWorkbenchID = s.project.id
        await vm.loadSessions(projectID: s.project.id)
        let p = s.project.id
        vm.setLayout(Self.split(.session(s.first.id), .board), projectID: p)
        vm.toggleSplit(projectID: p)
        XCTAssertFalse(vm.layout(projectID: p).isSplit)

        XCTAssertThrowsError(try button(help: "Show one pane", controls(vm, s.project)))
        try button(help: "Split: show two panes side by side", controls(vm, s.project)).tap()
        XCTAssertTrue(vm.layout(projectID: p).isSplit)

        XCTAssertNoThrow(try button(help: "Show one pane", controls(vm, s.project)))
        XCTAssertThrowsError(try button(help: "Split: show two panes side by side", controls(vm, s.project)))
    }

    // MARK: - ⋯ menu

    /// Show in Finder leads the menu (call 2: the folder crumb is gone);
    /// Repair install, Re-run Setup and Delete… keep their actions; Repair
    /// stays off while nothing needs repairing.
    func testTheMoreMenuItemsKeepTheirActions() async throws {
        let s = try await seed()
        let p = s.project.id
        let more = try controls(makeVM(), s.project).inspect()
            .find(ViewType.Menu.self) { try $0.help().string() == "Workbench actions" }
        let first = try more.find(ViewType.Button.self)
        XCTAssertEqual(try first.labelView().label().title().text().string(), "Show in Finder")
        XCTAssertEqual(try first.help().string(), "\(s.project.folderPath)\nShow in Finder")

        let healthy = makeVM(FakeCLIRunner(stdout: Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8)))
        await healthy.refreshInstallStatus(projectID: p)
        XCTAssertThrowsError(try controls(healthy, s.project).inspect().find(button: "Repair install").tap(),
                             "nothing to repair")

        let runner = FakeCLIRunner(stdout: Data(#"{"skill":"missing","hook":false,"mcp":true}"#.utf8))
        let vm = makeVM(runner)
        await vm.refreshInstallStatus(projectID: p)
        var deletes = 0
        let sut = controls(vm, s.project) { deletes += 1 }

        try sut.inspect().find(button: "Repair install").tap()
        await waitUntil { runner.invocations.contains(["integrate", "claude-code", "--workbench", String(p)]) }
        await waitUntil { !vm.isInstalling(projectID: p) }
        try controls(vm, s.project).inspect().find(button: "Re-run Setup").tap()
        await waitUntil { runner.invocations.contains(["workbench", "resync", String(p), "--json"]) }
        try sut.inspect().find(button: "Delete…").tap()
        XCTAssertEqual(deletes, 1)
    }

    /// "Clean Up Old Worktrees…" opens the sweep (board #535); off without a
    /// cleanup center.
    func testCleanUpOldWorktreesOpensTheSweep() async throws {
        let s = try await seed()
        let vm = makeVM(FakeCLIRunner())
        XCTAssertTrue(try controls(vm, s.project).inspect().find(button: "Clean Up Old Worktrees…").isDisabled())

        vm.sessionCleanup = SessionCleanupCenter(runner: nil)
        var opened = 0
        let open = { opened += 1 }
        try controls(vm, s.project, onCleanUp: open).inspect().find(button: "Clean Up Old Worktrees…").tap()
        XCTAssertEqual(opened, 1)
    }

    /// "New Automation…" lives in the ⚡ menu (spec 2026-10-20 §1) and
    /// opens the New automation sheet for this workbench; no ⚡ menu (the
    /// Automations view model not up yet), no item — the ⋯ menu has none.
    func testNewAutomationOpensTheSheetForThisWorkbench() async throws {
        let s = try await seed()
        let vm = makeVM(FakeCLIRunner())
        XCTAssertThrowsError(try controls(vm, s.project).inspect().find(button: "New Automation…"))

        var opened = 0
        let automations = WorkbenchAutomationsMenu(
            project: s.project,
            vm: AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: FakeCLIRunner())) { _ in },
            openRun: { _, _ in },
            onNewAutomation: { opened += 1 }
        )
        let sut = controls(vm, s.project, automations: automations)
        let bolt = try sut.inspect().find(ViewType.Menu.self) { try $0.help().string() == "Automations of this workbench" }
        try bolt.find(button: "New Automation…").tap()
        XCTAssertEqual(opened, 1)
        let items = try sut.inspect().findAll(ViewType.Text.self) { try $0.string() == "New Automation…" }
        XCTAssertEqual(items.count, 1, "only the ⚡ menu has it")
    }

    /// "Archive Closed Targets Now" sets the stamp and a second press moves
    /// it forward; "Undo Archive Now" shows only while it is set and clears
    /// it (board #415).
    func testArchiveNowAndUndoArchiveNow() async throws {
        let s = try await seed()
        let p = s.project.id
        let vm = makeVM()
        await vm.reload()
        let stamp = { try await self.pool.read { try WorkbenchQueries.fetch($0, id: p)?.archivedThrough } }
        XCTAssertThrowsError(try controls(vm, s.project).inspect().find(button: "Undo Archive Now"), "nothing to undo")

        try controls(vm, s.project).inspect().find(button: "Archive Closed Targets Now").tap()
        await waitUntil { vm.summaries.first?.project.archivedThrough != nil }
        let stamped = try XCTUnwrap(vm.summaries.first?.project)
        let stored = try await stamp()
        XCTAssertNotNil(stored)

        // Pressing again moves the moment forward. The stamp has second
        // precision, so date the first one back before the second press.
        let earlier = "2000-01-01T00:00:00Z"
        try await pool.write { d in
            try d.execute(sql: "UPDATE projects SET archived_through = ? WHERE id = ?", arguments: [earlier, p])
        }
        await vm.reload()
        XCTAssertEqual(vm.summaries.first?.project.archivedThrough, earlier)
        try controls(vm, stamped).inspect().find(button: "Archive Closed Targets Now").tap()
        await waitUntil { (vm.summaries.first?.project.archivedThrough ?? earlier) > earlier }
        let restamped = try await stamp()
        let moved = try XCTUnwrap(restamped, "pressing again keeps a stamp")
        XCTAssertGreaterThan(moved, earlier, "pressing again moves the moment")

        try controls(vm, stamped).inspect().find(button: "Undo Archive Now").tap()
        await waitUntil { vm.summaries.first?.project.archivedThrough == nil }
        let cleared = try await stamp()
        XCTAssertNil(cleared)
    }
}

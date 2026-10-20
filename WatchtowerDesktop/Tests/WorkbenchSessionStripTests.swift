import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The session strip on top of every session pane (spec 2026-10-20 §2 and
/// calls 8–10): where it shows, its toggles, its sessions menu and its
/// Terminal | Workchat acting on its own slot, the crumbs on the strip that
/// owns the code root, and expand / close in a split only.
@MainActor
final class WorkbenchSessionStripTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var center: TerminalCenter!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchSessionStripTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt strip \(UUID().uuidString)", isDirectory: true)
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

    private func makeVM() -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: center)
        vm.titleService = { _ in .init(title: "", written: false) }
        return vm
    }

    private struct Seeded {
        let project: Workbench
        let first: TerminalSession
        let second: TerminalSession
    }

    /// A workbench on a real folder with two `claude` sessions, "one" and
    /// "two", none started.
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

    private func loaded() async throws -> (WorkbenchesViewModel, Seeded) {
        let s = try await seed()
        let vm = makeVM()
        vm.selectedWorkbenchID = s.project.id
        await vm.loadSessions(projectID: s.project.id)
        return (vm, s)
    }

    /// `first` and `second` side by side.
    private static func split(_ first: WorkspacePane, _ second: WorkspacePane) -> WorkspaceLayout {
        var layout = WorkspaceLayout.default
        layout.show(first)
        layout.split(with: second)
        return layout
    }

    /// A session pane is inspected hidden: its content (the terminal, the
    /// report…) reads the app's state, the strip above it does not.
    private func pane(
        _ vm: WorkbenchesViewModel,
        _ project: Workbench,
        _ pane: WorkspacePane,
        isSplit: Bool
    ) throws -> InspectableView<ViewType.ClassifiedView> {
        try WorkspacePaneView(vm: vm, project: project, pane: pane, isSplit: isSplit, isExpanded: false,
                              isHidden: WorkspaceLayout.sessionID(ofAny: pane) != nil)
            .inspect()
    }

    /// The strip of session pane `pane`, as the layout now draws it.
    private func strip(_ vm: WorkbenchesViewModel, _ project: Workbench, _ pane: WorkspacePane) -> WorkbenchSessionStrip {
        let layout = vm.layout(projectID: project.id)
        return WorkbenchSessionStrip(
            vm: vm, project: project, pane: pane, sessionID: WorkspaceLayout.sessionID(ofAny: pane) ?? -1,
            isSplit: layout.isSplit, isExpanded: layout.expanded == pane
        )
    }

    private static func title(_ toggle: InspectableView<ViewType.Toggle>) throws -> String {
        try toggle.labelView().label().title().text().string()
    }

    private func toggle(_ title: String, _ sut: WorkbenchSessionStrip) throws -> InspectableView<ViewType.Toggle> {
        try sut.inspect().find(ViewType.Toggle.self) { try Self.title($0) == title }
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

    // MARK: - Where it shows

    /// Every pane of a session — terminal, Workchat, report, Changes — has
    /// the strip, single and split; a Files pane (Board's and Analytics'
    /// twin here) has none single and keeps the old picker header in a split.
    func testStripShowsOnEverySessionPaneOnly() async throws {
        let (vm, s) = try await loaded()
        let id = s.first.id
        for sessionPane: WorkspacePane in [.session(id), .sessionChat(id), .sessionReport(id), .changes(id)] {
            for isSplit in [false, true] {
                XCTAssertNoThrow(try pane(vm, s.project, sessionPane, isSplit: isSplit).find(WorkbenchSessionStrip.self),
                                 "\(sessionPane) split=\(isSplit) has the strip")
            }
        }
        let picker = { (isSplit: Bool) in
            try self.pane(vm, s.project, .files, isSplit: isSplit)
                .find(ViewType.Menu.self) { try $0.help().string() == "Show something else in this pane" }
        }
        XCTAssertThrowsError(try pane(vm, s.project, .files, isSplit: false).find(WorkbenchSessionStrip.self))
        XCTAssertThrowsError(try picker(false), "a single Files pane has no header")
        XCTAssertThrowsError(try pane(vm, s.project, .files, isSplit: true).find(WorkbenchSessionStrip.self))
        XCTAssertNoThrow(try picker(true), "a split Files pane keeps its picker")
    }

    // MARK: - Toggles

    func testStripTogglesReadTerminalWorkchatReportChanges() async throws {
        let (vm, s) = try await loaded()
        let titles = try strip(vm, s.project, .session(s.first.id))
            .inspect()
            .findAll(ViewType.Toggle.self)
            .map(Self.title)
        XCTAssertEqual(titles, ["Terminal", "Workchat", "Report", "Changes"])
    }

    /// Each strip lights its own half: the terminal pane's Terminal, the
    /// Workchat pane's Workchat.
    func testStripLightsItsOwnHalf() async throws {
        let (vm, s) = try await loaded()
        let id = s.first.id
        vm.setLayout(Self.split(.session(id), .sessionChat(id)), projectID: s.project.id)
        XCTAssertTrue(try toggle("Terminal", strip(vm, s.project, .session(id))).isOn())
        XCTAssertFalse(try toggle("Workchat", strip(vm, s.project, .session(id))).isOn())
        XCTAssertFalse(try toggle("Terminal", strip(vm, s.project, .sessionChat(id))).isOn())
        XCTAssertTrue(try toggle("Workchat", strip(vm, s.project, .sessionChat(id))).isOn())
    }

    /// Report keeps today's action: on puts the report beside its
    /// session's terminal, off closes it.
    func testStripReportTogglesTheReportBesideItsSession() async throws {
        let (vm, s) = try await loaded()
        let p = s.project.id
        let terminal = WorkspacePane.session(s.first.id)
        vm.setLayout(Self.split(terminal, .board), projectID: p)
        try toggle("Report", strip(vm, s.project, terminal)).tap()
        await waitUntil { vm.layout(projectID: p).visiblePanes == [terminal, .sessionReport(s.first.id)] }
        XCTAssertTrue(try toggle("Report", strip(vm, s.project, terminal)).isOn())
        try toggle("Report", strip(vm, s.project, terminal)).tap()
        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [terminal])
    }

    /// Report and Changes follow the strip's own session: two sessions side
    /// by side, the second strip's Report puts the second session's report
    /// on screen and lights on that strip only; Changes is never disabled.
    func testStripReportAndChangesFollowTheStripsSession() async throws {
        let (vm, s) = try await loaded()
        let p = s.project.id
        let (one, two) = (s.first.id, s.second.id)
        vm.setLayout(Self.split(.session(one), .session(two)), projectID: p)
        XCTAssertFalse(try toggle("Changes", strip(vm, s.project, .session(two))).isDisabled())

        try toggle("Report", strip(vm, s.project, .session(two))).tap()
        let panes = vm.layout(projectID: p).visiblePanes
        XCTAssertTrue(panes.contains(.sessionReport(two)), "\(panes)")
        XCTAssertFalse(panes.contains(.sessionReport(one)))
        XCTAssertTrue(try toggle("Report", strip(vm, s.project, .session(two))).isOn())
        XCTAssertFalse(try toggle("Report", strip(vm, s.project, .sessionReport(two))).isDisabled())

        vm.setLayout(Self.split(.session(one), .session(two)), projectID: p)
        try toggle("Changes", strip(vm, s.project, .session(two))).tap()
        XCTAssertTrue(vm.layout(projectID: p).visiblePanes.contains(.changes(two)))
        XCTAssertTrue(try toggle("Changes", strip(vm, s.project, .changes(two))).isOn())
        XCTAssertFalse(try toggle("Changes", strip(vm, s.project, .session(one))).isOn(),
                       "another session's Changes does not light this strip")
    }

    // MARK: - Its own slot

    /// On a report or Changes pane, Terminal and Workchat put this strip's
    /// session in this pane only, in the chosen mode; the other pane stays.
    func testStripModeOnAReportPaneReplacesThisPaneOnly() async throws {
        let (vm, s) = try await loaded()
        let p = s.project.id
        let one = s.first.id
        vm.setLayout(Self.split(.sessionReport(one), .board), projectID: p)
        try toggle("Terminal", strip(vm, s.project, .sessionReport(one))).tap()
        await waitUntil { vm.layout(projectID: p).visiblePanes == [.session(one), .board] }

        vm.setLayout(Self.split(.changes(one), .board), projectID: p)
        try toggle("Workchat", strip(vm, s.project, .changes(one))).tap()
        await waitUntil { vm.layout(projectID: p).visiblePanes == [.sessionChat(one), .board] }
        XCTAssertEqual(vm.layout(projectID: p).pane(forSession: one), .sessionChat(one), "the mode is recorded")
    }

    /// A mode already on screen in the other pane is disabled on this
    /// strip, not a click that does nothing or only flips the recorded mode.
    func testStripModeShownInTheOtherPaneIsDisabled() async throws {
        let (vm, s) = try await loaded()
        let p = s.project.id
        let one = s.first.id
        vm.setLayout(Self.split(.session(one), .sessionChat(one)), projectID: p)
        XCTAssertTrue(try toggle("Workchat", strip(vm, s.project, .session(one))).isDisabled())
        XCTAssertTrue(try toggle("Terminal", strip(vm, s.project, .sessionChat(one))).isDisabled())
        XCTAssertFalse(try toggle("Terminal", strip(vm, s.project, .session(one))).isDisabled())

        vm.setLayout(Self.split(.session(one), .sessionReport(one)), projectID: p)
        XCTAssertTrue(try toggle("Terminal", strip(vm, s.project, .sessionReport(one))).isDisabled())
        XCTAssertFalse(try toggle("Workchat", strip(vm, s.project, .sessionReport(one))).isDisabled())
    }

    /// The sessions menu ticks off the pane's own session on a report or
    /// Changes pane too; the other sessions stay enabled.
    func testStripSessionsMenuDisablesThePanesOwnSession() async throws {
        let (vm, s) = try await loaded()
        vm.setLayout(Self.split(.sessionReport(s.first.id), .board), projectID: s.project.id)
        for pane: WorkspacePane in [.sessionReport(s.first.id), .changes(s.first.id), .sessionChat(s.first.id)] {
            let menu = try strip(vm, s.project, pane).inspect().find(WorkbenchSessionsMenu.self)
            XCTAssertTrue(try menu.find(button: "one").isDisabled(), "\(pane)")
            XCTAssertFalse(try menu.find(button: "two").isDisabled(), "\(pane)")
        }
    }

    /// In a split, the strip's sessions menu replaces its own slot only.
    func testStripSessionsMenuActsOnItsOwnSlot() async throws {
        let (vm, s) = try await loaded()
        let p = s.project.id
        vm.setLayout(Self.split(.session(s.first.id), .board), projectID: p)

        let sessions = try strip(vm, s.project, .session(s.first.id)).inspect().find(WorkbenchSessionsMenu.self)
        XCTAssertNoThrow(try sessions.find(text: "one"), "the menu's label names the pane's session")
        try sessions.find(button: "two").tap()
        await waitUntil { vm.layout(projectID: p).visiblePanes == [.session(s.second.id), .board] }
    }

    /// A split of a terminal and its report stays paired when the session
    /// changes, from the terminal strip's sessions menu and from a panel click.
    func testASplitKeepsTheTerminalAndItsReportPairedWhenTheSessionChanges() async throws {
        let (vm, s) = try await loaded()
        let p = s.project.id
        vm.setLayout(Self.split(.session(s.first.id), .sessionReport(s.first.id)), projectID: p)

        let sessions = try strip(vm, s.project, .session(s.first.id)).inspect().find(WorkbenchSessionsMenu.self)
        try sessions.find(button: "two").tap()
        await waitUntil { vm.layout(projectID: p).visiblePanes == [.session(s.second.id), .sessionReport(s.second.id)] }

        await vm.showSession(id: s.first.id)
        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [.session(s.first.id), .sessionReport(s.first.id)])
    }

    /// Terminal | Workchat swaps this pane only: in place on a single pane,
    /// and in a split the other pane stays.
    func testStripTerminalWorkchatSwapsThisPaneOnly() async throws {
        let (vm, s) = try await loaded()
        let p = s.project.id
        let one = s.first.id
        vm.setLayout({ var l = WorkspaceLayout.default; l.show(.session(one)); return l }(), projectID: p)

        try toggle("Workchat", strip(vm, s.project, .session(one))).tap()
        await waitUntil { vm.layout(projectID: p).visiblePanes == [.sessionChat(one)] }
        try toggle("Terminal", strip(vm, s.project, .sessionChat(one))).tap()
        await waitUntil { vm.layout(projectID: p).visiblePanes == [.session(one)] }

        vm.setLayout(Self.split(.session(one), .board), projectID: p)
        try toggle("Workchat", strip(vm, s.project, .session(one))).tap()
        await waitUntil { vm.layout(projectID: p).visiblePanes == [.sessionChat(one), .board] }
        XCTAssertEqual(vm.layout(projectID: p).pane(forSession: one), .sessionChat(one), "the mode is recorded")
    }

    // MARK: - Crumbs

    /// Two sessions side by side: the crumbs sit on the strip of the
    /// focused session only — the one whose place sets the page's root.
    func testCrumbsOnlyOnTheStripThatOwnsTheCodeRoot() async throws {
        let (vm, s) = try await loaded()
        let p = s.project.id
        vm.setLayout(Self.split(.session(s.first.id), .session(s.second.id)), projectID: p)
        XCTAssertTrue(vm.ownsCodeRoot(sessionID: s.first.id, projectID: p), "with no focus the first held session owns it")
        XCTAssertFalse(vm.ownsCodeRoot(sessionID: s.second.id, projectID: p))

        XCTAssertNoThrow(try strip(vm, s.project, .session(s.first.id)).inspect().find(WorkbenchBranchCrumb.self))
        XCTAssertNoThrow(try strip(vm, s.project, .session(s.first.id)).inspect().find(WorkbenchPlaceCrumb.self))
        XCTAssertThrowsError(try strip(vm, s.project, .session(s.second.id)).inspect().find(WorkbenchBranchCrumb.self))
        XCTAssertThrowsError(try strip(vm, s.project, .session(s.second.id)).inspect().find(WorkbenchPlaceCrumb.self))
    }

    /// The focused session owns the root even when it is the second pane:
    /// the crumbs move to its strip.
    func testCrumbsFollowTheFocusedSession() async throws {
        let (vm, s) = try await loaded()
        let p = s.project.id
        await vm.showSession(id: s.first.id)
        await vm.showSession(id: s.second.id)
        vm.setLayout(Self.split(.session(s.first.id), .session(s.second.id)), projectID: p)
        center.focus(s.second.id)
        XCTAssertEqual(vm.activeSessionID(projectID: p), s.second.id)

        XCTAssertTrue(vm.ownsCodeRoot(sessionID: s.second.id, projectID: p))
        XCTAssertFalse(vm.ownsCodeRoot(sessionID: s.first.id, projectID: p))
        XCTAssertNoThrow(try strip(vm, s.project, .session(s.second.id)).inspect().find(WorkbenchBranchCrumb.self))
        XCTAssertThrowsError(try strip(vm, s.project, .session(s.first.id)).inspect().find(WorkbenchBranchCrumb.self))
    }

    // MARK: - Expand and close

    func testExpandAndCloseOnlyInASplit() async throws {
        let (vm, s) = try await loaded()
        let p = s.project.id
        let terminal = WorkspacePane.session(s.first.id)
        // By help: ViewInspector reads no accessibility label on this SDK.
        let close = { (sut: WorkbenchSessionStrip) in
            try sut.inspect().find(ViewType.Button.self) { try $0.help().string() == "Close this pane" }
        }
        let expand = { (sut: WorkbenchSessionStrip) in
            try sut.inspect().find(ViewType.Button.self) { try $0.help().string() == "Expand this pane" }
        }
        vm.setLayout({ var l = WorkspaceLayout.default; l.show(terminal); return l }(), projectID: p)
        XCTAssertThrowsError(try close(strip(vm, s.project, terminal)))
        XCTAssertThrowsError(try expand(strip(vm, s.project, terminal)))

        vm.setLayout(Self.split(terminal, .board), projectID: p)
        XCTAssertNoThrow(try expand(strip(vm, s.project, terminal)))
        try close(strip(vm, s.project, terminal)).tap()
        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [.board])
    }
}

import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The workbench header's `Terminal ▾ | Session | Board | Files | split | ⋯`
/// (spec 2026-10-03-workbench-session-report Part 7, the owner's pick on
/// board #357): the buttons' order, what each toggle does, the Session
/// view's pairing with its session in a split, and the ⋯ menu's actions.
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

    private func controls(_ vm: WorkbenchesViewModel, _ project: Workbench, onDelete: @escaping () -> Void = {})
        -> WorkbenchHeaderControls {
        WorkbenchHeaderControls(vm: vm, project: project, onDelete: onDelete)
    }

    private static func title(_ toggle: InspectableView<ViewType.Toggle>) throws -> String {
        try toggle.labelView().label().title().text().string()
    }

    /// The view button titled `title`, read off a fresh body (each body
    /// captures the layout it was drawn for).
    private func toggle(_ title: String, _ sut: WorkbenchHeaderControls) throws -> InspectableView<ViewType.Toggle> {
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

    // MARK: - View buttons

    /// The owner's pick: Terminal ▾ | Session | Board | Files, the sessions
    /// chevron on the Terminal button only.
    func testTheViewButtonsReadTerminalSessionBoardFiles() async throws {
        let s = try await seed()
        let sut = controls(makeVM(), s.project)

        // The view buttons' own ForEach: the … menu holds toggles too (the
        // archive setting's choices).
        let buttons = try sut.inspect().find(ViewType.ForEach.self)
        let titles = try buttons.findAll(ViewType.Toggle.self).map(Self.title)
        XCTAssertEqual(titles, ["Terminal", "Session", "Board", "Files"])
        XCTAssertNoThrow(try buttons.tupleView(0).find(ViewType.Menu.self), "the sessions chevron sits by Terminal")
        for index in 1..<4 {
            XCTAssertThrowsError(try buttons.tupleView(index).find(ViewType.Menu.self), "no chevron by \(titles[index])")
        }
    }

    /// Every view button toggles its view as before, the Session button
    /// included: on puts it beside the terminal in a split (the Session view
    /// beside its own session), off closes that pane of the split.
    func testEveryViewButtonTogglesItsView() async throws {
        let s = try await seed()
        let vm = makeVM()
        vm.selectedWorkbenchID = s.project.id
        await vm.loadSessions(projectID: s.project.id)
        let p = s.project.id
        let terminal = WorkspacePane.session(s.first.id)
        vm.setLayout(Self.split(terminal, .board), projectID: p)
        let panes = { vm.layout(projectID: p).visiblePanes }

        XCTAssertTrue(try toggle("Board", controls(vm, s.project)).isOn())
        XCTAssertFalse(try toggle("Session", controls(vm, s.project)).isOn())
        try toggle("Session", controls(vm, s.project)).tap()
        await waitUntil { panes() == [terminal, .sessionReport(s.first.id)] }
        XCTAssertTrue(try toggle("Session", controls(vm, s.project)).isOn())
        XCTAssertFalse(try toggle("Board", controls(vm, s.project)).isOn())

        try toggle("Session", controls(vm, s.project)).tap()
        XCTAssertEqual(panes(), [terminal], "off closes the Session pane, the terminal stays")

        vm.toggleSplit(projectID: p)
        try toggle("Files", controls(vm, s.project)).tap()
        await waitUntil { panes() == [terminal, .files] }
        try toggle("Board", controls(vm, s.project)).tap()
        await waitUntil { panes() == [terminal, .board] }
        try toggle("Board", controls(vm, s.project)).tap()
        XCTAssertEqual(panes(), [terminal])

        try toggle("Session", controls(vm, s.project)).tap()
        await waitUntil { panes() == [terminal, .sessionReport(s.first.id)] }
        XCTAssertTrue(vm.layout(projectID: p).isSplit, "from a single pane: the terminal and its report")
        try toggle("Terminal", controls(vm, s.project)).tap()
        XCTAssertEqual(panes(), [.sessionReport(s.first.id)], "Terminal off closes the terminal pane")
        try toggle("Session", controls(vm, s.project)).tap()
        XCTAssertEqual(panes(), [.sessionReport(s.first.id)], "a single pane is never removed")
        try toggle("Terminal", controls(vm, s.project)).tap()
        await waitUntil { vm.layout(projectID: p).isShowing(.terminal) }
    }

    /// A split of a terminal and its report stays paired when the session
    /// changes, from the Terminal ▾ menu and from a panel click.
    func testASplitKeepsTheTerminalAndItsReportPairedWhenTheSessionChanges() async throws {
        let s = try await seed()
        let vm = makeVM()
        vm.selectedWorkbenchID = s.project.id
        await vm.loadSessions(projectID: s.project.id)
        let p = s.project.id
        vm.setLayout(Self.split(.session(s.first.id), .sessionReport(s.first.id)), projectID: p)

        let sessions = try controls(vm, s.project).inspect()
            .find(ViewType.Menu.self) { try $0.accessibilityLabel().string() == "Sessions" }
        try sessions.find(button: "two").tap()
        await waitUntil { vm.layout(projectID: p).visiblePanes == [.session(s.second.id), .sessionReport(s.second.id)] }

        await vm.showSession(id: s.first.id)
        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [.session(s.first.id), .sessionReport(s.first.id)])
    }

    // MARK: - ⋯ menu

    /// Repair install, Re-run Setup and Delete… keep their actions; Repair
    /// stays off while nothing needs repairing.
    func testTheMoreMenuItemsKeepTheirActions() async throws {
        let s = try await seed()
        let p = s.project.id
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
}

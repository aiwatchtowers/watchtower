import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Fast switches between a workbench's sessions (board #187): the session
/// clicked last is the one on screen — in the layout, in the panel's tab and
/// in the terminal host — however the switches' awaits (the list load, the
/// `touch` write, a resume's start) complete.
@MainActor
final class WorkbenchSessionSwitchTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var folder: URL!
    private var appState: AppState!
    private var projectID: Int64 = 0

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folderPath = folder.path
        projectID = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: folderPath) }
        appState = AppState()
        // pid 0: nothing here ever signals a real process group.
        appState.terminalCenter.makeProcess = { FakeTerminalSession(pid: 0) }
        appState.terminalCenter.transcriptExists = { _ in true }
        // The VM keeps layouts in `UserDefaults.standard`: none left from
        // an earlier run of this workbench id.
        UserDefaults.standard.removeObject(forKey: WorkspaceLayout.key(workbenchID: projectID))
        appState.initWorkbenches(
            dbPool: pool, cliRunner: nil, notifier: RecordingWorkbenchNotifier(),
            sessionNotifier: RecordingSessionNotifier()
        )
    }

    override func tearDown() async throws {
        appState.workbenchNotificationCenter?.stop()
        appState.sessionAgentStateCenter?.stop()
        UserDefaults.standard.removeObject(forKey: WorkspaceLayout.key(workbenchID: projectID))
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        appState = nil
    }

    private var vm: WorkbenchesViewModel {
        get throws { try XCTUnwrap(appState.workbenchesViewModel) }
    }

    private func insertSession(_ title: String) async throws -> TerminalSession {
        let projectID = projectID
        let folderPath = folder.path
        return try await pool.write { db in
            try TerminalSessionQueries.create(db, .init(
                projectID: projectID, kind: .claude, title: title,
                folderPath: folderPath, claudeSessionID: UUID().uuidString.lowercased()
            ))
        }
    }

    /// The workbench page with `running` started and shown in turn (the last
    /// one on screen), the panel's list loaded.
    private func page(running: [TerminalSession]) async throws -> WorkbenchesViewModel {
        let vm = try vm
        await vm.reload()
        vm.selectedWorkbenchID = projectID
        await vm.loadSessions(projectID: projectID)
        for session in running { await vm.showSession(id: session.id) }
        return vm
    }

    private func onScreen(_ vm: WorkbenchesViewModel) -> WorkspacePane? {
        vm.layout(projectID: projectID).visiblePanes.first
    }

    // MARK: - The view model

    /// A click whose switch has more to await — here a row the panel's list
    /// has not read yet, so it is loaded first — must not land after a later
    /// click and put its session back on screen.
    func testALaterClickWinsOverASlowerEarlierOne() async throws {
        let a = try await insertSession("a")
        let vm = try await page(running: [a])
        // Not in the loaded list: its switch reads the list first.
        let b = try await insertSession("b")

        let first = Task { await vm.showSession(id: b.id) }
        let second = Task { await vm.showSession(id: a.id) }
        _ = await (first.value, second.value)

        XCTAssertEqual(onScreen(vm), .session(a.id), "the session clicked last is on screen")
        XCTAssertEqual(vm.panelSelection, .session(a.id))
        XCTAssertEqual(appState.terminalCenter.focusOrder.last, a.id, "and is the one Send comments goes to")
    }

    /// A → B → A while B resumes (not running, not yet in the list): A ends
    /// on screen, and B's resume still ran — the owner did click it.
    func testABAWhileBResumesEndsOnA() async throws {
        let a = try await insertSession("a")
        let vm = try await page(running: [a])
        let b = try await insertSession("b")
        XCTAssertNil(appState.terminalCenter.states[b.id])

        let toB = Task { await vm.showSession(id: b.id) }
        let backToA = Task { await vm.showSession(id: a.id) }
        let toBAgain = Task { await vm.showSession(id: b.id) }
        let lastA = Task { await vm.showSession(id: a.id) }
        _ = await (toB.value, backToA.value, toBAgain.value, lastA.value)

        XCTAssertEqual(onScreen(vm), .session(a.id))
        XCTAssertEqual(vm.panelSelection, .session(a.id))
        XCTAssertEqual(appState.terminalCenter.states[b.id], .running, "the superseded click still started its session")
        XCTAssertEqual(appState.terminalCenter.focusOrder.last, a.id)
    }

    /// One click alone still switches (the ordering guard never blocks the
    /// latest switch).
    func testASingleClickSwitches() async throws {
        let a = try await insertSession("a")
        let b = try await insertSession("b")
        let vm = try await page(running: [a])

        await vm.showSession(id: b.id)

        XCTAssertEqual(onScreen(vm), .session(b.id))
        XCTAssertEqual(vm.panelSelection, .session(b.id))
        XCTAssertEqual(appState.terminalCenter.focusOrder.last, b.id)
    }

    /// The click made last fails (its row was deleted elsewhere): its error
    /// stays on the page — the slower, superseded click landing afterwards
    /// neither clears it nor puts its own session on screen.
    func testTheLatestSwitchsErrorSurvivesASupersededOne() async throws {
        let shown = try await insertSession("shown")
        let gone = try await insertSession("gone")
        let vm = try await page(running: [shown])
        try await pool.write { try TerminalSessionQueries.delete($0, id: gone.id) }
        let slow = try await insertSession("slow") // not in the loaded list

        let first = Task { await vm.showSession(id: slow.id) }
        let second = Task { await vm.showSession(id: gone.id) }
        _ = await (first.value, second.value)

        XCTAssertNotNil(vm.sessionErrors[projectID], "the failed click says so")
        XCTAssertEqual(onScreen(vm), .session(shown.id), "the superseded click moves nothing")
    }

    /// The superseded click fails, the latest one works: no banner about the
    /// superseded one beside the session on screen.
    func testASupersededSwitchsFailureShowsNoBanner() async throws {
        let a = try await insertSession("a")
        let b = try await insertSession("b")
        let vm = try await page(running: [a])
        let gone = try await insertSession("gone") // not listed: read first
        try await pool.write { try TerminalSessionQueries.delete($0, id: gone.id) }

        let first = Task { await vm.showSession(id: gone.id) }
        let second = Task { await vm.showSession(id: b.id) }
        _ = await (first.value, second.value)

        XCTAssertEqual(onScreen(vm), .session(b.id))
        XCTAssertNil(vm.sessionErrors[projectID])
    }

    /// A layout change of the owner's own (here the Board button) made while
    /// a slower session switch is pending wins: the switch lands without
    /// covering the Board, and its session still starts.
    func testAViewButtonSupersedesAPendingSwitch() async throws {
        let a = try await insertSession("a")
        let vm = try await page(running: [a])
        let project = try XCTUnwrap(vm.selectedWorkbench)
        let slow = try await insertSession("slow")

        let click = Task { await vm.showSession(id: slow.id) }
        let board = Task { await vm.showView(.board, project: project) }
        _ = await (click.value, board.value)

        XCTAssertEqual(onScreen(vm), .board)
        XCTAssertEqual(appState.terminalCenter.states[slow.id], .running)
    }

    /// Work on it reads the target first; a panel click made during that
    /// read is the later one and wins. The work-on session is still created
    /// and started — it shows in the panel, not on screen.
    func testAClickDuringWorkOnsReadWins() async throws {
        let a = try await insertSession("a")
        let other = try await insertSession("other")
        let vm = try await page(running: [other])
        let projectID = projectID
        let target = try await pool.write {
            try TestDatabase.insertWorkbenchTarget($0, projectID: projectID, text: "Ship it")
        }

        let workOn = Task { await vm.workOn(targetID: target, targetText: "Ship it", projectID: projectID) }
        let click = Task { await vm.showSession(id: a.id) }
        _ = await (workOn.value, click.value)

        XCTAssertEqual(onScreen(vm), .session(a.id))
        XCTAssertEqual(appState.terminalCenter.focusOrder.last, a.id)
        let created = try await pool.read { try TerminalSessionQueries.fetchForTarget($0, targetID: target) }
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first.flatMap { appState.terminalCenter.states[$0.id] }, .running)
    }

    // MARK: - On screen

    /// The real workspace in a window: after every burst of fast switches —
    /// A → B → A, with and without the run loop turning between the clicks,
    /// and a switch to a session still resuming — the terminal in the window
    /// is the one session the panel's tab marks, the one clicked last. (The
    /// rounds over listed, running sessions lost their last click only now
    /// and then before the fix — the writes resumed out of order at times;
    /// the VM tests above pin the ordering deterministically.)
    func testTheTerminalOnScreenIsTheSelectedSessionAfterFastSwitches() async throws {
        let a = try await insertSession("a")
        let b = try await insertSession("b")
        let vm = try await page(running: [a, b])
        let project = try XCTUnwrap(vm.selectedWorkbench)
        let host = NSHostingView(rootView: WorkspaceAreaView(vm: vm, project: project).environment(appState))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        settle(0.05)

        var sessionIDs = [a.id, b.id]
        func terminalsOnScreen() -> [Int64] {
            sessionIDs.filter { appState.terminalCenter.process(for: $0)?.view.window === window }
        }
        func assertOnScreen(_ id: Int64, _ label: String) {
            XCTAssertEqual(vm.panelSelection, .session(id), "\(label): the tab")
            // The hosts attach on SwiftUI's next pass: waited for, bounded.
            let deadline = Date().addingTimeInterval(2)
            while terminalsOnScreen() != [id], Date() < deadline { settle(0.01) }
            XCTAssertEqual(terminalsOnScreen(), [id], "\(label): the terminal")
        }
        assertOnScreen(b.id, "start")

        for round in 0..<6 {
            var clicks: [Task<Void, Never>] = []
            for (index, id) in [a.id, b.id, a.id].enumerated() {
                clicks.append(Task { await vm.showSession(id: id) })
                if (round + index).isMultiple(of: 2) { settle(0) }
            }
            for click in clicks { await click.value }
            assertOnScreen(a.id, "round \(round), A → B → A")
            await vm.showSession(id: b.id)
            assertOnScreen(b.id, "round \(round), back to B")
        }

        // A session that is not running yet (its resume starts on the click)
        // and is not in the panel's list yet.
        let c = try await insertSession("c")
        sessionIDs.append(c.id)
        let toC = Task { await vm.showSession(id: c.id) }
        let toA = Task { await vm.showSession(id: a.id) }
        _ = await (toC.value, toA.value)
        assertOnScreen(a.id, "a switch away from a resuming session")
        await vm.showSession(id: c.id)
        assertOnScreen(c.id, "the resumed session")
    }

    /// Turns the run loop: SwiftUI applies pending updates, the hosts their
    /// deferred work.
    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

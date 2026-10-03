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
        appState.initWorkbenches(
            dbPool: pool, cliRunner: nil, notifier: RecordingWorkbenchNotifier(),
            sessionNotifier: RecordingSessionNotifier()
        )
    }

    override func tearDown() async throws {
        appState.workbenchNotificationCenter?.stop()
        appState.sessionAgentStateCenter?.stop()
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
        XCTAssertEqual(appState.terminalCenter.focusOrder.last, b.id)
    }

    // MARK: - On screen

    /// The real workspace in a window: after every burst of fast switches —
    /// A → B → A, with and without the run loop turning between the clicks,
    /// and a switch to a session still resuming — the terminal in the window
    /// is the one session the panel's tab marks, the one clicked last.
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
        settle()

        var sessionIDs = [a.id, b.id]
        func terminalsOnScreen() -> [Int64] {
            sessionIDs.filter { appState.terminalCenter.process(for: $0)?.view.window === window }
        }
        func assertOnScreen(_ id: Int64, _ label: String) {
            XCTAssertEqual(vm.panelSelection, .session(id), "\(label): the tab")
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
            settle()
            assertOnScreen(a.id, "round \(round), A → B → A")
            await vm.showSession(id: b.id)
            settle()
            assertOnScreen(b.id, "round \(round), back to B")
        }

        // A session that is not running yet (its resume starts on the click)
        // and is not in the panel's list yet.
        let c = try await insertSession("c")
        sessionIDs.append(c.id)
        let toC = Task { await vm.showSession(id: c.id) }
        let toA = Task { await vm.showSession(id: a.id) }
        _ = await (toC.value, toA.value)
        settle()
        assertOnScreen(a.id, "a switch away from a resuming session")
        await vm.showSession(id: c.id)
        settle()
        assertOnScreen(c.id, "the resumed session")
    }

    /// Lets SwiftUI apply the pending updates and the hosts' deferred work.
    private func settle(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

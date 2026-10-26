import AppKit
import GRDB
import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Clean Up screen covers the workspace area (board #1107, spec
/// 2026-10-26-worktree-cleanup-screen §3.1): the panes behind it stay in the
/// view tree, so a session's terminal is neither detached nor re-created by
/// opening and closing it, and the layout is never touched. Terminals are
/// fake (pid 0) and the cleanup runs are doubles: nothing is spawned.
@MainActor
final class CleanupScreenViewTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var folder: URL!
    private var appState: AppState!
    private var projectID: Int64 = 0
    private var streamer: RepliedCleanupStreamer!

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt-cover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folderPath = folder.path
        projectID = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: folderPath) }
        appState = AppState(workbenchDefaults: AppState.isolatedDefaults)
        appState.terminalCenter.makeProcess = { FakeTerminalSession(pid: 0) }
        appState.terminalCenter.transcriptExists = { _ in true }
        appState.workbenchDefaults.removeObject(forKey: WorkspaceLayout.key(workbenchID: projectID))
        appState.initWorkbenches(
            dbPool: pool, cliRunner: nil, notifier: RecordingWorkbenchNotifier(),
            sessionNotifier: RecordingSessionNotifier()
        )
        streamer = RepliedCleanupStreamer(replies: [.success(CleanupFixture.plan)])
        let center = SessionCleanupCenter(runner: FakeSessionCleanupRunner(replies: []), streamer: streamer)
        center.liveSessionIDs = { [terminals = appState.terminalCenter] in terminals.liveIDs }
        try XCTUnwrap(appState.workbenchesViewModel).sessionCleanup = center
    }

    override func tearDown() async throws {
        streamer?.finishAll()
        appState.workbenchNotificationCenter?.stop()
        appState.sessionAgentStateCenter?.stop()
        appState.workbenchDefaults.removeObject(forKey: WorkspaceLayout.key(workbenchID: projectID))
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        appState = nil
    }

    func testScreenCoversTheWorkspaceWithoutRecreatingIt() async throws {
        let vm = try XCTUnwrap(appState.workbenchesViewModel)
        let projectID = projectID
        let folderPath = folder.path
        let session = try await pool.write { db in
            try TerminalSessionQueries.create(db, .init(
                projectID: projectID, kind: .claude, title: "Login redirect",
                folderPath: folderPath, claudeSessionID: UUID().uuidString.lowercased()
            ))
        }
        await vm.reload()
        vm.selectedWorkbenchID = projectID
        await vm.loadSessions(projectID: projectID)
        await vm.showSession(id: session.id)
        let project = try XCTUnwrap(vm.selectedWorkbench)
        let process = try XCTUnwrap(appState.terminalCenter.process(for: session.id) as? FakeTerminalSession)

        let host = NSHostingView(rootView: CleanupCoveredWorkspace(vm: vm, project: project).environment(appState))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        waitFor { process.view.window === window }
        XCTAssertTrue(process.view.window === window, "the terminal is on screen")
        let terminalHost = try XCTUnwrap(process.view.superview)
        let layout = vm.layout(projectID: projectID)

        await vm.openCleanupScreen(projectID: projectID).value
        settle(0.1)
        XCTAssertTrue(vm.cleanupScreenOpen(projectID: projectID))
        XCTAssertTrue(process.view.window === window, "covered, not taken out of the window")
        XCTAssertTrue(process.view.superview === terminalHost, "the same terminal host view")
        XCTAssertFalse(process.detached, "the terminal was never detached")
        XCTAssertEqual(vm.layout(projectID: projectID), layout, "the screen is not a layout value")

        vm.closeCleanupScreen(projectID: projectID)
        settle(0.1)
        XCTAssertFalse(vm.cleanupScreenOpen(projectID: projectID))
        XCTAssertTrue(process.view.window === window)
        XCTAssertTrue(process.view.superview === terminalHost, "closing shows the very same terminal")
        XCTAssertFalse(process.detached)
        XCTAssertTrue(appState.terminalCenter.process(for: session.id) === process, "never re-created")
        XCTAssertEqual(appState.terminalCenter.states[session.id], .running)
        XCTAssertEqual(vm.layout(projectID: projectID), layout)
    }

    /// The footer (mockups A, B, F): Clean Up… waits with nothing ticked;
    /// with a tick it can go; while another cleanup of the workbench runs
    /// (a Delete and Clean Up) the total reads "Another cleanup is running"
    /// and Clean Up… waits again, ticking still possible.
    func testFooterWaitsForTicksAndForAnotherCleanup() async throws {
        let vm = try XCTUnwrap(appState.workbenchesViewModel)
        let projectID = projectID
        await vm.openCleanupScreen(projectID: projectID).value
        let worktree = "worktree:/tmp/example/.claude/worktrees/x"

        func footer() throws -> CleanupFooter {
            let state = try XCTUnwrap(vm.cleanupScreens[projectID])
            return CleanupFooter(
                vm: vm, projectID: projectID, model: try XCTUnwrap(vm.cleanupScreenModel(projectID: projectID)),
                state: state, phase: vm.sessionCleanup?.cleanupPhase(for: state.scope) ?? .idle,
                ticks: .constant(state.ticks), confirming: .constant(false)
            )
        }

        XCTAssertTrue(try footer().inspect().find(button: "Clean Up…").isDisabled(), "nothing ticked")
        XCTAssertNoThrow(try footer().inspect().find(text: "Nothing selected"))
        XCTAssertThrowsError(try footer().inspect().find(button: "Clear"), "nothing to clear")

        vm.cleanupScreens[projectID]?.ticks = [worktree]
        XCTAssertFalse(try footer().inspect().find(button: "Clean Up…").isDisabled())
        XCTAssertNoThrow(try footer().inspect().find(button: "Clear"))
        XCTAssertThrowsError(try footer().inspect().find(text: CleanupFooter.anotherRunning))

        vm.cleanupRunWorkbenches[99] = projectID
        XCTAssertTrue(try footer().inspect().find(button: "Clean Up…").isDisabled(), "one cleanup per workbench")
        XCTAssertNoThrow(try footer().inspect().find(text: "Another cleanup is running"))
        XCTAssertFalse(try footer().inspect().find(button: "Select All That Can Go").isDisabled(), "ticking stays")
        vm.cleanupRunWorkbenches[99] = nil
    }

    /// Turns the run loop until `condition` holds, bounded.
    private func waitFor(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { settle(0.01) }
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

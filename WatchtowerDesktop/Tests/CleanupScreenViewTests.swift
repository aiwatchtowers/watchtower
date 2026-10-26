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
        // A terminal view that takes the keyboard, as the real one does.
        appState.terminalCenter.makeProcess = { FakeTerminalSession(pid: 0, view: KeyTakingView()) }
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

    private func page(showing session: TerminalSession) async throws -> WorkbenchesViewModel {
        let vm = try XCTUnwrap(appState.workbenchesViewModel)
        await vm.reload()
        vm.selectedWorkbenchID = projectID
        await vm.loadSessions(projectID: projectID)
        await vm.showSession(id: session.id)
        return vm
    }

    func testScreenCoversTheWorkspaceWithoutRecreatingIt() async throws {
        let session = try await insertSession("Login redirect")
        let vm = try await page(showing: session)
        let projectID = projectID
        let project = try XCTUnwrap(vm.selectedWorkbench)
        let process = try XCTUnwrap(appState.terminalCenter.process(for: session.id) as? FakeTerminalSession)

        let host = NSHostingView(rootView: WorkbenchCoveredWorkspace(vm: vm, project: project).environment(appState))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        waitFor { process.view.window === window }
        XCTAssertTrue(process.view.window === window, "the terminal is on screen")
        let terminalHost = try XCTUnwrap(process.view.superview)
        let layout = vm.layout(projectID: projectID)
        // Positive control: uncovered, a focus request gives the terminal the keyboard.
        appState.terminalCenter.requestKeyboardFocus(session.id)
        try await drainMainQueue()
        XCTAssertTrue(window.firstResponder === process.view, "the fake terminal takes the keyboard")

        await vm.openCleanupScreen(projectID: projectID).value
        settle(0.1)
        try await drainMainQueue()
        XCTAssertTrue(vm.isObscured(sessionID: session.id, projectID: projectID))
        XCTAssertFalse(window.firstResponder === process.view, "keys go to the screen, not the hidden terminal")
        appState.terminalCenter.requestKeyboardFocus(session.id)
        settle(0.1)
        try await drainMainQueue()
        XCTAssertFalse(window.firstResponder === process.view, "a focus request does not reach the covered terminal")
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

    /// Picking a session (the sessions panel) puts it on screen: the Clean
    /// Up screen closes first, as a tab click does (spec §3.1).
    func testShowingASessionClosesTheScreen() async throws {
        let first = try await insertSession("first")
        let second = try await insertSession("second")
        let vm = try await page(showing: first)
        await vm.openCleanupScreen(projectID: projectID).value
        XCTAssertTrue(vm.cleanupScreenOpen(projectID: projectID))

        await vm.showSession(id: second.id)

        XCTAssertFalse(vm.cleanupScreenOpen(projectID: projectID))
        XCTAssertEqual(vm.layout(projectID: projectID).visiblePanes.first, .session(second.id))
    }

    /// Agent Settings is a page screen like Clean Up (board #1150): it
    /// covers the terminal, one page screen at a time replaces the other,
    /// and a session put on screen closes it.
    func testAgentSettingsIsAPageScreen() async throws {
        let first = try await insertSession("first")
        let second = try await insertSession("second")
        let vm = try await page(showing: first)
        let layout = vm.layout(projectID: projectID)
        XCTAssertNil(vm.pageScreen(projectID: projectID))

        vm.openAgentSettingsScreen(projectID: projectID)
        XCTAssertEqual(vm.pageScreen(projectID: projectID), .agentSettings)
        XCTAssertTrue(vm.isObscured(sessionID: first.id, projectID: projectID))
        XCTAssertEqual(vm.layout(projectID: projectID), layout, "the screen is not a layout value")

        await vm.openCleanupScreen(projectID: projectID).value
        XCTAssertEqual(vm.pageScreen(projectID: projectID), .cleanUp, "Clean Up takes its place")
        vm.openAgentSettingsScreen(projectID: projectID)
        XCTAssertEqual(vm.pageScreen(projectID: projectID), .agentSettings, "and gives it back")
        XCTAssertFalse(vm.cleanupScreenOpen(projectID: projectID))

        await vm.showSession(id: second.id)
        XCTAssertNil(vm.pageScreen(projectID: projectID))
        XCTAssertFalse(vm.isObscured(sessionID: second.id, projectID: projectID))

        vm.openAgentSettingsScreen(projectID: projectID)
        vm.closePageScreen(projectID: projectID)
        XCTAssertNil(vm.pageScreen(projectID: projectID))
    }

    /// Leaving for another workbench and coming back is not an owner pick:
    /// the screen is still open with its ticks and its ready plan (spec
    /// §3.1), and the session behind it stays covered.
    func testWorkbenchRoundTripKeepsTheScreen() async throws {
        let session = try await insertSession("Login redirect")
        let vm = try await page(showing: session)
        let projectID = projectID
        let other = try await pool.write { try TestDatabase.insertWorkbench($0, name: "gizmo", folder: "/tmp/example-gizmo") }
        await vm.reload()
        await vm.openCleanupScreen(projectID: projectID).value
        guard case .ready = vm.sessionCleanup?.cleanupPhase(for: .workbench(projectID)) else { return XCTFail("no plan") }
        let worktree = "worktree:/tmp/example/.claude/worktrees/x"
        vm.cleanupScreens[projectID]?.ticks = [worktree]

        await vm.switchTo(workbenchID: other)
        await vm.switchTo(workbenchID: projectID)

        XCTAssertTrue(vm.cleanupScreenOpen(projectID: projectID), "the screen is still open")
        XCTAssertEqual(vm.cleanupScreens[projectID]?.ticks, [worktree])
        guard case .ready = vm.sessionCleanup?.cleanupPhase(for: .workbench(projectID)) else {
            return XCTFail("the ready plan is kept")
        }
        XCTAssertTrue(vm.isObscured(sessionID: session.id, projectID: projectID))
    }

    /// ⌘A and Esc are the screen's only while the Search field does not have
    /// the keyboard; there they select and clear its text.
    func testShortcutsStepAsideForTheSearchField() {
        let free = CleanupFooter.shortcuts(searchFocused: false)
        XCTAssertEqual(free.selectAll, KeyboardShortcut("a", modifiers: .command))
        XCTAssertEqual(free.clear, KeyboardShortcut(.escape, modifiers: []))
        let typing = CleanupFooter.shortcuts(searchFocused: true)
        XCTAssertNil(typing.selectAll)
        XCTAssertNil(typing.clear)
    }

    /// After an apply the ticks can be left on rows that are gone or now
    /// kept: they are not live, and **Clear** does not show for them.
    func testClearHiddenOnStaleOnlyTicks() {
        let gone = "worktree:/tmp/example/.claude/worktrees/gone"
        let kept = SessionCleanupItem(key: "worktree:/tmp/example/.claude/worktrees/moved", kind: .worktree,
                                      action: .keep, reason: .known(.moved))
        let open = SessionCleanupItem(key: "branch:feat/open", kind: .branch, action: .remove)
        let model = CleanupScreenModel(items: [kept, open], checking: [], sizing: [], now: Date())
        XCTAssertFalse(CleanupFooter.showsClear(live: model.liveTicks([gone, kept.key])), "stale ticks only")
        XCTAssertTrue(CleanupFooter.showsClear(live: model.liveTicks([gone, open.key])))
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
                state: state,
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

    /// Clean Up… waits while a row of the plan is still being checked (an
    /// apply would stop the plan and leave those rows unknown), and the
    /// view model refuses the apply then; sizes still coming in do not hold
    /// it.
    func testCleanUpWaitsWhileRowsAreStillChecked() async throws {
        let vm = try XCTUnwrap(appState.workbenchesViewModel)
        let projectID = projectID
        let scripted = ScriptedCleanupStreamer()
        defer { scripted.finishAll() }
        let center = SessionCleanupCenter(runner: FakeSessionCleanupRunner(replies: []), streamer: scripted)
        center.eventBatchInterval = .zero
        center.baseEnvironment = { ["PATH": "/usr/bin"] }
        vm.sessionCleanup = center
        _ = vm.openCleanupScreen(projectID: projectID)
        await waitUntil("the plan's run") { scripted.runs.count == 1 }
        let run = try XCTUnwrap(scripted.runs.first)
        run.send(CleanupStreamFixture.listed)
        run.send(CleanupStreamFixture.checked(CleanupStreamFixture.wtA))
        await waitUntil("wtA checked") {
            guard let progress = vm.cleanupScreenProgress(projectID: projectID) else { return false }
            return progress.items.count == 3 && !progress.checking.contains(CleanupStreamFixture.wtA)
        }
        vm.cleanupScreens[projectID]?.ticks = [CleanupStreamFixture.wtA]

        func cleanUpDisabled() throws -> Bool {
            let state = try XCTUnwrap(vm.cleanupScreens[projectID])
            return try CleanupFooter(
                vm: vm, projectID: projectID, model: try XCTUnwrap(vm.cleanupScreenModel(projectID: projectID)),
                state: state, ticks: .constant(state.ticks), confirming: .constant(false)
            ).inspect().find(button: "Clean Up…").isDisabled()
        }

        XCTAssertTrue(vm.cleanupStillChecking(projectID: projectID))
        XCTAssertTrue(try cleanUpDisabled(), "wtB and the branch are still being checked")
        let refused = await vm.applyCleanupScreen(projectID: projectID)
        XCTAssertFalse(refused)
        XCTAssertEqual(scripted.runs.count, 1, "no apply launched, the plan not stopped")
        XCTAssertEqual(run.stopCount, 0)

        run.send(CleanupStreamFixture.checked(CleanupStreamFixture.wtB))
        run.send(CleanupStreamFixture.checked(CleanupStreamFixture.branchA, kind: "branch"))
        await waitUntil("every row checked") { vm.cleanupStillChecking(projectID: projectID) == false }
        XCTAssertFalse(vm.cleanupScreenProgress(projectID: projectID)?.sizing.isEmpty ?? true, "sizes still come in")
        XCTAssertFalse(try cleanUpDisabled(), "sizing does not hold Clean Up…")
    }

    /// The footer never mistakes the screen's own apply for another cleanup
    /// (the line is the total while it runs), and names an apply of the
    /// other scope as one: the screen widened while a session's ran.
    func testOwnApplyIsNotAnotherCleanup() async throws {
        let vm = try XCTUnwrap(appState.workbenchesViewModel)
        let projectID = projectID
        await vm.openCleanupScreen(projectID: projectID).value
        let state = try XCTUnwrap(vm.cleanupScreens[projectID])
        vm.sweepRuns[projectID] = Task { false }
        vm.sweepRunScopes[projectID] = state.scope
        defer {
            vm.sweepRuns[projectID] = nil
            vm.sweepRunScopes[projectID] = nil
        }
        let footer = CleanupFooter(
            vm: vm, projectID: projectID, model: try XCTUnwrap(vm.cleanupScreenModel(projectID: projectID)),
            state: state, ticks: .constant([]), confirming: .constant(false)
        )
        XCTAssertThrowsError(try footer.inspect().find(text: CleanupFooter.anotherRunning))
        XCTAssertTrue(try footer.inspect().find(button: "Clean Up…").isDisabled(), "its own apply still runs")

        vm.sweepRunScopes[projectID] = .session(5)
        XCTAssertNoThrow(try footer.inspect().find(text: CleanupFooter.anotherRunning), "a session's apply is another")
        XCTAssertTrue(try footer.inspect().find(button: "Clean Up…").isDisabled())
    }

    /// The terminal host moves the keyboard in a main-queue block, which runs
    /// only once this test's main-actor job suspends: suspend, then turn the
    /// run loop.
    private func drainMainQueue() async throws {
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(20))
            settle(0.02)
        }
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

/// A terminal stand-in that accepts the keyboard, like the real terminal view.
private final class KeyTakingView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

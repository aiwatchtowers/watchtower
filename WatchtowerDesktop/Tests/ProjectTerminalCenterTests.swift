import XCTest
import AppKit
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class FakeTerminalSession: ProjectTerminalSession {
    let view = NSView()
    var pid: pid_t
    var onExit: ((Int32?) -> Void)?
    private(set) var launches: [TerminalLaunch] = []
    private(set) var detached = false
    private(set) var inputs: [[UInt8]] = []
    var bracketedPasteMode = true

    init(pid: pid_t = 4242) {
        self.pid = pid
    }

    func start(_ launch: TerminalLaunch) { launches.append(launch) }
    func detach() { detached = true }
    func sendInput(_ bytes: [UInt8]) { inputs.append(bytes) }
    func exit(_ code: Int32?) { onExit?(code) }
}

@MainActor
final class ProjectTerminalCenterTests: XCTestCase {
    private var folder: URL!
    private var sessions: [FakeTerminalSession] = []
    private var signals: [(pid_t, Int32)] = []
    private var slept: Duration = .zero
    private var alive = true
    private var exitOnHangup = true

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt term \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        sessions = []
        signals = []
        slept = .zero
        alive = true
        exitOnHangup = true
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func project(id: Int64 = 1, folder path: String? = nil) throws -> Project {
        let queue = try TestDatabase.create()
        return try queue.write { d in
            try d.execute(sql: "INSERT INTO projects (id, name, folder_path) VALUES (?, 'acme', ?)", arguments: [id, path ?? folder.path])
            return try XCTUnwrap(ProjectQueries.fetch(d, id: id))
        }
    }

    private func makeCenter(pid: pid_t = 4242) -> ProjectTerminalCenter {
        let center = ProjectTerminalCenter(
            makeSession: { [weak self] in
                let session = FakeTerminalSession(pid: pid)
                self?.sessions.append(session)
                return session
            },
            signaller: ProcessGroupSignaller(
                signal: { [weak self] pid, sig in
                    guard let self else { return }
                    self.signals.append((pid, sig))
                    if sig == SIGHUP, self.exitOnHangup { self.sessions.last?.exit(nil) }
                    if sig == SIGKILL { self.alive = false }
                },
                isAlive: { [weak self] _ in self?.alive ?? false },
                sleep: { [weak self] step in self?.slept += step }
            )
        )
        center.shell = { "/bin/zsh" }
        return center
    }

    func testStartLaunchesTheLoginShellInTheFolder() throws {
        let center = makeCenter()
        let p = try project()
        center.start(project: p, firstRun: true)
        XCTAssertEqual(center.states[p.id], .running)
        let launch = try XCTUnwrap(sessions.first?.launches.first)
        XCTAssertEqual(sessions.first?.launches.count, 1)
        XCTAssertEqual(launch.executable, "/bin/zsh")
        XCTAssertEqual(launch.currentDirectory, folder.path)
        XCTAssertTrue(launch.args.last?.hasPrefix("exec claude --session-id ") == true)
        XCTAssertTrue(launch.args.last?.hasSuffix("'\(TerminalLaunch.firstRunPrompt)'") == true)
    }

    func testStartWhileRunningIsANoOp() throws {
        let center = makeCenter()
        let p = try project()
        center.start(project: p, firstRun: true)
        center.start(project: p, firstRun: false)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].launches.count, 1)
    }

    /// House rule: the terminal outlives the view that shows it. The view only
    /// hosts the session's NSView; tearing the host down leaves the process
    /// and its scrollback in the center, and coming back re-hosts the same one.
    func testSessionSurvivesTheViewGoingAwayAndIsReusedOnReturn() throws {
        let appState = AppState()
        appState.projectTerminalCenter.makeSession = { [weak self] in
            let session = FakeTerminalSession()
            self?.sessions.append(session)
            return session
        }
        appState.projectTerminalCenter.shell = { "/bin/zsh" }
        let center = appState.projectTerminalCenter
        let p = try project()
        appState.selectedDestination = .projects
        center.start(project: p)

        let host = NSView()
        let first = try XCTUnwrap(center.session(for: p.id))
        host.addSubview(first.view)
        first.view.removeFromSuperview()          // the pane's view is dismantled
        appState.selectedDestination = .inbox     // navigate away …
        appState.selectedDestination = .projects  // … and back

        center.start(project: p)                  // the pane asks again on appear
        XCTAssertTrue(center.session(for: p.id) === first)
        XCTAssertEqual(center.states[p.id], .running)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].launches.count, 1)
    }

    func testExitShowsExitedAndStartRelaunchesInTheSameSessionWithoutThePrompt() throws {
        let center = makeCenter()
        let p = try project()
        center.start(project: p, firstRun: true)
        sessions[0].exit(0)
        XCTAssertEqual(center.states[p.id], .exited(0))
        center.start(project: p)
        XCTAssertEqual(sessions.count, 1)
        let relaunch = try XCTUnwrap(sessions[0].launches.last?.args.last)
        XCTAssertTrue(relaunch.hasPrefix("exec claude --session-id "))
        XCTAssertFalse(relaunch.contains("'"))
        XCTAssertEqual(center.states[p.id], .running)
    }

    func testCloseSendsHangupThenKillOnlyWhenStillAlive() async throws {
        let center = makeCenter()
        let p = try project()

        // Polite exit: SIGHUP is enough.
        center.start(project: p)
        await center.close(projectID: p.id)
        XCTAssertEqual(signals.map(\.1), [SIGHUP])
        XCTAssertEqual(signals.map(\.0), [4242])
        XCTAssertTrue(sessions[0].detached)
        XCTAssertNil(center.states[p.id])
        XCTAssertNil(center.session(for: p.id))

        // Stubborn child: SIGKILL after the 3 s grace.
        signals = []
        exitOnHangup = false
        alive = true
        center.start(project: p)
        await center.close(projectID: p.id)
        XCTAssertEqual(signals.map(\.1), [SIGHUP, SIGKILL])
        XCTAssertEqual(slept, ProjectTerminalCenter.killGrace)
    }

    func testCloseNeverSignalsANonPositivePid() async throws {
        let center = makeCenter(pid: 0)
        let p = try project()
        center.start(project: p)
        await center.close(projectID: p.id)
        XCTAssertTrue(signals.isEmpty, "killpg(0, …) would signal Watchtower's own process group")
        XCTAssertTrue(sessions[0].detached)
    }

    func testCloseOfAnExitedSessionSendsNothing() async throws {
        let center = makeCenter()
        let p = try project()
        center.start(project: p)
        sessions[0].exit(1)
        await center.close(projectID: p.id)
        XCTAssertTrue(signals.isEmpty)
    }

    func testMissingFolderIsUnavailableAndStartsNothing() throws {
        let center = makeCenter()
        let p = try project(folder: "/tmp/does-not-exist-\(UUID().uuidString)")
        center.start(project: p, firstRun: true)
        guard case .unavailable = center.states[p.id] else {
            return XCTFail("expected unavailable, got \(String(describing: center.states[p.id]))")
        }
        XCTAssertTrue(sessions.isEmpty)
    }

    func testCloseAllClosesEverySession() async throws {
        // `exitOnHangup`'s mock always exits `sessions.last` (there is no
        // per-pid session table to disambiguate — both fakes share the
        // default pid), which would race one project's close against the
        // other's here. Two live sessions is exactly the case that mock
        // doesn't model; disable it so the test only exercises what it's
        // for — that closeAll signals every session.
        exitOnHangup = false
        let center = makeCenter()
        let one = try project(id: 1)
        let two = try project(id: 2)
        center.start(project: one)
        center.start(project: two)
        await center.closeAll()
        XCTAssertEqual(signals.filter { $0.1 == SIGHUP }.count, 2)
        XCTAssertTrue(center.states.isEmpty)
    }

    // MARK: - Send comments (Task 26)

    func testARunningSessionGetsOneBracketedPasteWithNoEnter() throws {
        let center = makeCenter()
        let p = try project()
        center.start(project: p)
        let line = ProjectCommentPrompt.line(relPath: "docs/plan.md", documentID: 7, count: 3)
        XCTAssertEqual(center.sendPrompt(line, projectID: p.id), .sent)
        XCTAssertEqual(sessions[0].inputs, [
            [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] + Array(line.utf8) + [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        ])
        XCTAssertFalse(sessions[0].inputs[0].contains(0x0D), "the owner presses Return; Watchtower never does")
        XCTAssertFalse(center.clipboardHints.contains(p.id))
    }

    /// Without bracketed paste nothing is typed — keystrokes could answer a
    /// pending permission prompt — the line goes to the clipboard instead.
    func testWithoutBracketedPasteTheLineIsCopiedNotTyped() throws {
        let center = makeCenter()
        var copied: [String] = []
        center.copyToClipboard = { copied.append($0) }
        let p = try project()
        center.start(project: p)
        sessions[0].bracketedPasteMode = false

        XCTAssertEqual(center.sendPrompt("Address it", projectID: p.id), .copied)
        XCTAssertTrue(sessions[0].inputs.isEmpty, "no keystrokes reach the terminal")
        XCTAssertEqual(copied, ["Address it"])
        XCTAssertTrue(center.clipboardHints.contains(p.id))

        center.dismissClipboardHint(projectID: p.id)
        XCTAssertFalse(center.clipboardHints.contains(p.id))
    }

    func testAnExitedSessionReceivesNothing() throws {
        let center = makeCenter()
        let p = try project()
        center.start(project: p)
        sessions[0].exit(0)
        XCTAssertEqual(center.sendPrompt("x", projectID: p.id), .noSession)
        XCTAssertTrue(sessions[0].inputs.isEmpty)
    }

    func testNoSessionStartsNothing() throws {
        let center = makeCenter()
        let p = try project()
        XCTAssertEqual(center.sendPrompt("x", projectID: p.id), .noSession)
        XCTAssertTrue(sessions.isEmpty, "sending never starts a session")
        XCTAssertNil(center.states[p.id])
    }
}

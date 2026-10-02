import XCTest
import AppKit
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class FakeTerminalSession: TerminalSessionProcess {
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
final class TerminalCenterTests: XCTestCase {
    private var folder: URL!
    private var queue: DatabaseQueue!
    private var sessions: [FakeTerminalSession] = []
    private var signals: [(pid_t, Int32)] = []
    private var slept: Duration = .zero
    private var alive = true
    private var exitOnHangup = true
    private var nextPid: pid_t = 4242
    /// Session ids Claude Code has a transcript for.
    private var transcripts: Set<String> = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt term \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        queue = try TestDatabase.create()
        sessions = []
        signals = []
        slept = .zero
        alive = true
        exitOnHangup = true
        nextPid = 4242
        transcripts = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func projectID(_ id: Int64 = 1) throws -> Int64 {
        try queue.write { d in
            try d.execute(sql: "INSERT OR IGNORE INTO projects (id, name, folder_path) VALUES (?, ?, ?)",
                          arguments: [id, "acme \(id)", "\(folder.path)/\(id)"])
            return id
        }
    }

    /// A `terminal_sessions` row. The CHECK forbids a claude row without a
    /// session id, so an invalid one is written raw afterwards.
    private func row(
        project: Int64? = 1,
        kind: TerminalSession.Kind = .claude,
        uuid: String? = UUID().uuidString.lowercased(),
        folder path: String? = nil
    ) throws -> TerminalSession {
        let projectID = try project.map { try self.projectID($0) }
        return try queue.write { d in
            try TerminalSessionQueries.create(d, .init(
                projectID: projectID, kind: kind, title: "s",
                folderPath: path ?? folder.path, claudeSessionID: kind == .claude ? uuid : nil
            ))
        }
    }

    private func makeCenter(pid: pid_t = 4242) -> TerminalCenter {
        nextPid = pid
        let center = TerminalCenter(
            makeProcess: { [weak self] in
                guard let self else { return FakeTerminalSession() }
                let session = FakeTerminalSession(pid: self.nextPid)
                if self.nextPid > 0 { self.nextPid += 1 }
                self.sessions.append(session)
                return session
            },
            signaller: ProcessGroupSignaller(
                signal: { [weak self] pid, sig in
                    guard let self else { return }
                    self.signals.append((pid, sig))
                    if sig == SIGHUP, self.exitOnHangup { self.sessions.first { $0.pid == pid }?.exit(nil) }
                    if sig == SIGKILL { self.alive = false }
                },
                isAlive: { [weak self] _ in self?.alive ?? false },
                sleep: { [weak self] step in self?.slept += step }
            )
        )
        center.shell = { "/bin/zsh" }
        center.transcriptExists = { [weak self] in self?.transcripts.contains($0) ?? false }
        return center
    }

    func testFreshStartLaunchesTheSessionIDAndPromptInTheFolder() throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true, prompt: TerminalLaunch.firstRunPrompt(.current))
        XCTAssertEqual(center.states[s.id], .running)
        XCTAssertEqual(center.liveIDs, [s.id])
        let launch = try XCTUnwrap(sessions.first?.launches.first)
        XCTAssertEqual(sessions.first?.launches.count, 1)
        XCTAssertEqual(launch.executable, "/bin/zsh")
        XCTAssertEqual(launch.currentDirectory, folder.path)
        XCTAssertEqual(launch.args.last,
                       "exec claude --session-id \(try XCTUnwrap(s.claudeSessionID)) '\(TerminalLaunch.firstRunPrompt(.current))'")
    }

    func testNonFreshStartResumesTheStoredSession() throws {
        let center = makeCenter()
        let s = try row()
        transcripts = [try XCTUnwrap(s.claudeSessionID)]
        center.start(s, fresh: false)
        let args = try XCTUnwrap(sessions.first?.launches.first?.args)
        XCTAssertEqual(args.last, "exec claude --resume \(try XCTUnwrap(s.claudeSessionID))")
        XCTAssertFalse(args.joined(separator: " ").contains("--session-id"))
    }

    /// No transcript (never typed into, or the first start failed): --resume
    /// would be refused on every Restart, so the same id starts anew.
    func testNonFreshStartWithoutATranscriptStartsTheSameIDAnew() throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: false, prompt: TerminalLaunch.firstRunPrompt(.current))
        XCTAssertEqual(sessions.first?.launches.first?.args.last,
                       "exec claude --session-id \(try XCTUnwrap(s.claudeSessionID))")
    }

    func testInvalidSessionIDIsUnavailableEvenWithATranscriptLookup() throws {
        let center = makeCenter()
        var asked = false
        center.transcriptExists = { _ in asked = true; return true }
        let s = try row()
        try queue.write { d in
            try d.execute(sql: "UPDATE terminal_sessions SET claude_session_id = ? WHERE id = ?",
                          arguments: ["NOT-A-UUID", s.id])
        }
        let tampered = try XCTUnwrap(queue.read { try TerminalSessionQueries.fetch($0, id: s.id) })
        center.start(tampered, fresh: false)
        guard case .unavailable = center.states[s.id] else { return XCTFail("expected unavailable") }
        XCTAssertFalse(asked)
        XCTAssertTrue(sessions.isEmpty)
    }

    /// An unavailable session still belongs to its project, so project
    /// delete clears it.
    func testUnavailableSessionIsClosedWithItsProject() async throws {
        let center = makeCenter()
        let missing = try row(folder: "/tmp/does-not-exist-\(UUID().uuidString)")
        center.start(missing, fresh: true)
        center.focus(missing.id)
        XCTAssertEqual(center.sessionIDs(ofWorkbench: 1), [missing.id])

        let ids = center.sessionIDs(ofWorkbench: 1)
        await center.closeAll { ids.contains($0) }

        XCTAssertTrue(center.states.isEmpty)
        XCTAssertTrue(center.focusOrder.isEmpty)
        XCTAssertTrue(center.sessionIDs(ofWorkbench: 1).isEmpty)
    }

    func testShellRowLaunchesTheLoginShellAlone() throws {
        let center = makeCenter()
        let s = try row(project: nil, kind: .shell)
        center.start(s, fresh: true, prompt: TerminalLaunch.firstRunPrompt(.current))
        XCTAssertEqual(sessions.first?.launches.first?.args, ["-l"])
        XCTAssertEqual(center.states[s.id], .running)
    }

    /// The id is interpolated into a shell command: anything but a canonical
    /// lowercase UUID launches nothing.
    func testInvalidSessionIDIsUnavailableAndLaunchesNothing() throws {
        let center = makeCenter()
        let s = try row()
        try queue.write { d in
            try d.execute(sql: "UPDATE terminal_sessions SET claude_session_id = ? WHERE id = ?",
                          arguments: ["x; rm -rf ~", s.id])
        }
        let tampered = try XCTUnwrap(queue.read { try TerminalSessionQueries.fetch($0, id: s.id) })
        center.start(tampered, fresh: false)
        guard case .unavailable = center.states[s.id] else {
            return XCTFail("expected unavailable, got \(String(describing: center.states[s.id]))")
        }
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(center.liveIDs.isEmpty)
    }

    func testStartWhileRunningIsANoOp() throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true, prompt: TerminalLaunch.firstRunPrompt(.current))
        center.start(s, fresh: false)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].launches.count, 1)
    }

    /// House rule: the terminal outlives the view that shows it. The view only
    /// hosts the session's NSView; tearing the host down leaves the process
    /// and its scrollback in the center, and coming back re-hosts the same one.
    func testSessionSurvivesTheViewGoingAwayAndIsReusedOnReturn() throws {
        let appState = AppState()
        appState.terminalCenter.makeProcess = { [weak self] in
            let session = FakeTerminalSession()
            self?.sessions.append(session)
            return session
        }
        appState.terminalCenter.shell = { "/bin/zsh" }
        let center = appState.terminalCenter
        let s = try row()
        appState.selectedDestination = .workbench
        center.start(s, fresh: true)

        let host = NSView()
        let first = try XCTUnwrap(center.process(for: s.id))
        host.addSubview(first.view)
        first.view.removeFromSuperview()          // the pane's view is dismantled
        appState.selectedDestination = .inbox     // navigate away …
        appState.selectedDestination = .workbench  // … and back

        center.start(s, fresh: false)             // the pane asks again on appear
        XCTAssertTrue(center.process(for: s.id) === first)
        XCTAssertEqual(center.states[s.id], .running)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].launches.count, 1)
    }

    func testExitShowsExitedAndStartRelaunchesInTheSameProcessViewWithResume() throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true, prompt: TerminalLaunch.firstRunPrompt(.current))
        transcripts = [try XCTUnwrap(s.claudeSessionID)]
        sessions[0].exit(0)
        XCTAssertEqual(center.states[s.id], .exited(0))
        XCTAssertTrue(center.liveIDs.isEmpty)
        center.start(s, fresh: false)
        XCTAssertEqual(sessions.count, 1)
        let relaunch = try XCTUnwrap(sessions[0].launches.last?.args.last)
        XCTAssertTrue(relaunch.hasPrefix("exec claude --resume "))
        XCTAssertFalse(relaunch.contains("'"))
        XCTAssertEqual(center.states[s.id], .running)
    }

    func testTwoSessionsOfOneProjectRunAtOnceAndCloseSignalsOnlyItsOwnPid() async throws {
        let center = makeCenter(pid: 100)
        let a = try row()
        let b = try row()
        center.start(a, fresh: true)
        center.start(b, fresh: true)
        XCTAssertEqual(center.liveIDs, [a.id, b.id])
        XCTAssertEqual(sessions.map(\.pid), [100, 101])

        await center.close(sessionID: a.id)

        XCTAssertEqual(signals.map(\.0), [100])
        XCTAssertEqual(signals.map(\.1), [SIGHUP])
        XCTAssertTrue(sessions[0].detached)
        XCTAssertFalse(sessions[1].detached)
        XCTAssertNil(center.states[a.id])
        XCTAssertEqual(center.states[b.id], .running)
    }

    func testCloseSendsHangupThenKillOnlyWhenStillAlive() async throws {
        let center = makeCenter()
        let s = try row()

        // Polite exit: SIGHUP is enough.
        center.start(s, fresh: true)
        await center.close(sessionID: s.id)
        XCTAssertEqual(signals.map(\.1), [SIGHUP])
        XCTAssertEqual(signals.map(\.0), [4242])
        XCTAssertTrue(sessions[0].detached)
        XCTAssertNil(center.states[s.id])
        XCTAssertNil(center.process(for: s.id))

        // Stubborn child: SIGKILL after the 3 s grace.
        signals = []
        exitOnHangup = false
        alive = true
        center.start(s, fresh: false)
        await center.close(sessionID: s.id)
        XCTAssertEqual(signals.map(\.1), [SIGHUP, SIGKILL])
        XCTAssertEqual(slept, TerminalCenter.killGrace)
    }

    func testCloseNeverSignalsANonPositivePid() async throws {
        let center = makeCenter(pid: 0)
        let s = try row()
        center.start(s, fresh: true)
        await center.close(sessionID: s.id)
        XCTAssertTrue(signals.isEmpty, "killpg(0, …) would signal Watchtower's own process group")
        XCTAssertTrue(sessions[0].detached)
    }

    func testCloseOfAnExitedSessionSendsNothing() async throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)
        sessions[0].exit(1)
        await center.close(sessionID: s.id)
        XCTAssertTrue(signals.isEmpty)
    }

    func testMissingFolderIsUnavailableAndStartsNothing() throws {
        let center = makeCenter()
        let s = try row(folder: "/tmp/does-not-exist-\(UUID().uuidString)")
        center.start(s, fresh: true, prompt: TerminalLaunch.firstRunPrompt(.current))
        guard case .unavailable = center.states[s.id] else {
            return XCTFail("expected unavailable, got \(String(describing: center.states[s.id]))")
        }
        XCTAssertTrue(sessions.isEmpty)
    }

    func testCloseAllClosesEverySession() async throws {
        let center = makeCenter(pid: 100)
        let one = try row(project: 1)
        let two = try row(project: 2)
        center.start(one, fresh: true)
        center.start(two, fresh: true)
        await center.closeAll()
        XCTAssertEqual(Set(signals.filter { $0.1 == SIGHUP }.map(\.0)), [100, 101])
        XCTAssertTrue(center.states.isEmpty)
        XCTAssertTrue(center.focusOrder.isEmpty)
    }

    /// Project delete closes only that project's sessions.
    func testCloseAllWhereClosesOnlyMatchingSessions() async throws {
        let center = makeCenter(pid: 100)
        let a1 = try row(project: 1)
        let a2 = try row(project: 1)
        let b = try row(project: 2)
        for s in [a1, a2, b] { center.start(s, fresh: true) }
        XCTAssertEqual(center.sessionIDs(ofWorkbench: 1), [a1.id, a2.id])

        let ofWorkbench = center.sessionIDs(ofWorkbench: 1)
        await center.closeAll { ofWorkbench.contains($0) }

        XCTAssertEqual(Set(signals.map(\.0)), [100, 101])
        XCTAssertEqual(center.liveIDs, [b.id])
        XCTAssertEqual(center.states[b.id], .running)
        XCTAssertTrue(center.sessionIDs(ofWorkbench: 1).isEmpty)
    }

    // MARK: - The branch switch's agent guard (#233)

    func testALiveClaudeRowOfTheWorkbenchCountsWhateverItsFolder() throws {
        let center = makeCenter()
        let s = try row(project: 1)
        center.start(s, fresh: true)
        XCTAssertTrue(center.hasLiveClaudeSession(workbenchID: 1, folder: "/tmp/elsewhere"))
        XCTAssertFalse(center.hasLiveClaudeSession(workbenchID: 2, folder: "/tmp/elsewhere"))
    }

    func testAShellRowDoesNotCount() throws {
        let center = makeCenter()
        center.start(try row(project: 1, kind: .shell), fresh: true)
        XCTAssertFalse(center.hasLiveClaudeSession(workbenchID: 1, folder: folder.path))
    }

    func testAnExitedClaudeRowDoesNotCount() throws {
        let center = makeCenter()
        let s = try row(project: 1)
        center.start(s, fresh: true)
        sessions.first?.exit(0)
        XCTAssertFalse(center.hasLiveClaudeSession(workbenchID: 1, folder: folder.path))
    }

    func testAStandaloneClaudeRowInsideTheFolderCounts() throws {
        let sub = folder.appendingPathComponent("sub/deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let center = makeCenter()
        center.start(try row(project: nil, folder: sub.path), fresh: true)
        XCTAssertTrue(center.hasLiveClaudeSession(workbenchID: 9, folder: folder.path))
        XCTAssertTrue(center.hasLiveClaudeSession(workbenchID: 9, folder: folder.path + "/"))
        XCTAssertTrue(center.hasLiveClaudeSession(workbenchID: 9, folder: sub.path))
    }

    func testAClaudeRowInAnotherFolderDoesNotCount() throws {
        let sub = folder.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let center = makeCenter()
        center.start(try row(project: nil, folder: sub.path), fresh: true)
        XCTAssertFalse(center.hasLiveClaudeSession(workbenchID: 9, folder: folder.appendingPathComponent("su").path),
                       "a sibling sharing a name prefix is not inside")
        XCTAssertFalse(center.hasLiveClaudeSession(workbenchID: 9, folder: sub.appendingPathComponent("child").path),
                       "a session in the parent is not inside a child folder")
    }

    func testFocusMovesAnIDToTheEndWithoutDuplicates() {
        let center = makeCenter()
        center.focus(1)
        center.focus(2)
        center.focus(3)
        center.focus(1)
        XCTAssertEqual(center.focusOrder, [2, 3, 1])
        center.focus(1)
        XCTAssertEqual(center.focusOrder, [2, 3, 1])
    }

    /// Send comments targets the most recently focused live claude session of
    /// the project — never a shell, never another project's session.
    func testActiveSessionIsTheLastFocusedLiveClaudeSessionOfTheProject() throws {
        let center = makeCenter()
        let a = try row(project: 1)
        let b = try row(project: 1)
        let shell = try row(project: 1, kind: .shell)
        let other = try row(project: 2)
        for s in [a, b, shell, other] { center.start(s, fresh: true) }
        center.focus(a.id)
        center.focus(shell.id)
        center.focus(other.id)
        XCTAssertEqual(center.activeSession(projectID: 1)?.id, a.id)
        sessions[0].exit(0)
        XCTAssertEqual(center.activeSession(projectID: 1)?.id, b.id)
        XCTAssertNil(center.activeSession(projectID: 3))
    }

    // MARK: - Send comments (Task 26)

    func testARunningSessionGetsOneBracketedPasteWithNoEnter() throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)
        let line = WorkbenchCommentPrompt.line(relPath: "docs/plan.md", documentID: 7, count: 3, vocabulary: .current)
        XCTAssertEqual(center.sendPrompt(line, sessionID: s.id), .sent)
        XCTAssertEqual(sessions[0].inputs, [
            [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] + Array(line.utf8) + [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        ])
        XCTAssertFalse(sessions[0].inputs[0].contains(0x0D), "the owner presses Return; Watchtower never does")
        XCTAssertFalse(center.clipboardHints.contains(s.id))
    }

    /// Without bracketed paste nothing is typed — keystrokes could answer a
    /// pending permission prompt — the line goes to the clipboard instead.
    func testWithoutBracketedPasteTheLineIsCopiedNotTyped() throws {
        let center = makeCenter()
        var copied: [String] = []
        center.copyToClipboard = { copied.append($0) }
        let s = try row()
        center.start(s, fresh: true)
        sessions[0].bracketedPasteMode = false

        XCTAssertEqual(center.sendPrompt("Address it", sessionID: s.id), .copied)
        XCTAssertTrue(sessions[0].inputs.isEmpty, "no keystrokes reach the terminal")
        XCTAssertEqual(copied, ["Address it"])
        XCTAssertTrue(center.clipboardHints.contains(s.id))

        center.dismissClipboardHint(sessionID: s.id)
        XCTAssertFalse(center.clipboardHints.contains(s.id))
    }

    func testAnExitedSessionReceivesNothing() throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)
        sessions[0].exit(0)
        XCTAssertEqual(center.sendPrompt("x", sessionID: s.id), .noSession)
        XCTAssertTrue(sessions[0].inputs.isEmpty)
    }

    func testNoSessionStartsNothing() throws {
        let center = makeCenter()
        let s = try row()
        XCTAssertEqual(center.sendPrompt("x", sessionID: s.id), .noSession)
        XCTAssertTrue(sessions.isEmpty, "sending never starts a session")
        XCTAssertNil(center.states[s.id])
    }
}

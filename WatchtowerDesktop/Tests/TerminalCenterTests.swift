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
    var onOwnerInput: (([UInt8]) -> Void)?
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

    private(set) var pathLinkFolder: String?
    private(set) var openPathLink: ((TerminalPathLinks.Location) -> Void)?
    func setPathLinkHandler(folder: String, open: @escaping (TerminalPathLinks.Location) -> Void) {
        pathLinkFolder = folder
        openPathLink = open
    }
}

@MainActor
final class TerminalCenterTests: XCTestCase {
    private var folder: URL!
    private var queue: DatabaseQueue!
    private var sessions: [FakeTerminalSession] = []
    private var signals: [(pid_t, Int32)] = []
    private var slept: Duration = .zero
    /// What the first session had received when each pause began.
    private var inputsAtSleep: [[[UInt8]]] = []
    /// Runs inside each pause (the owner typing meanwhile).
    private var onSleep: (() -> Void)?
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
        inputsAtSleep = []
        onSleep = nil
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
                sleep: { [weak self] step in
                    guard let self else { return }
                    slept += step
                    inputsAtSleep.append(sessions.first?.inputs ?? [])
                    onSleep?()
                }
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
        let uuid = try XCTUnwrap(s.claudeSessionID)
        XCTAssertEqual(launch.args.last,
                       "exec /bin/sh -c 'exec env -u WATCHTOWER_FIRST_PROMPT claude --session-id \(uuid) \"$WATCHTOWER_FIRST_PROMPT\"'")
        XCTAssertEqual(launch.environment.last, "WATCHTOWER_FIRST_PROMPT=\(TerminalLaunch.firstRunPrompt(.current))")
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
        let appState = AppState.isolated()
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
        XCTAssertTrue(center.hasLiveClaudeSession(workbenchID: 1, workTree: "/tmp/elsewhere"))
        XCTAssertFalse(center.hasLiveClaudeSession(workbenchID: 2, workTree: "/tmp/elsewhere"))
    }

    func testAShellRowDoesNotCount() throws {
        let center = makeCenter()
        center.start(try row(project: 1, kind: .shell), fresh: true)
        XCTAssertFalse(center.hasLiveClaudeSession(workbenchID: 1, workTree: folder.path))
    }

    func testAnExitedClaudeRowDoesNotCount() throws {
        let center = makeCenter()
        let s = try row(project: 1)
        center.start(s, fresh: true)
        sessions.first?.exit(0)
        XCTAssertFalse(center.hasLiveClaudeSession(workbenchID: 1, workTree: folder.path))
    }

    /// `folder` plays a repository; `dir` makes a folder inside it.
    private func dir(_ relative: String) throws -> URL {
        let url = folder.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testAStandaloneClaudeRowInsideTheWorkTreeCounts() throws {
        let deeper = try dir("sub/deeper")
        let center = makeCenter()
        center.start(try row(project: nil, folder: deeper.path), fresh: true)
        XCTAssertTrue(center.hasLiveClaudeSession(workbenchID: 9, workTree: folder.path))
        XCTAssertTrue(center.hasLiveClaudeSession(workbenchID: 9, workTree: folder.path + "/"))
        XCTAssertTrue(center.hasLiveClaudeSession(workbenchID: 9, workTree: deeper.path))
    }

    /// The workbench is `repo/app`; the switch swaps the whole checkout, so
    /// a session at the repository root works in the same files.
    func testASessionAtTheRepositoryRootOfASubfolderWorkbenchCounts() throws {
        _ = try dir("app")
        let center = makeCenter()
        center.start(try row(project: nil, folder: folder.path), fresh: true)
        XCTAssertTrue(center.hasLiveClaudeSession(workbenchID: 9, workTree: folder.path))
    }

    func testASessionInASiblingPackageOfTheSameRepositoryCounts() throws {
        _ = try dir("app")
        let sibling = try dir("lib")
        let center = makeCenter()
        center.start(try row(project: nil, folder: sibling.path), fresh: true)
        XCTAssertTrue(center.hasLiveClaudeSession(workbenchID: 9, workTree: folder.path))
    }

    func testASessionInAnotherRepositoryDoesNotCount() throws {
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("wt other \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        let center = makeCenter()
        center.start(try row(project: nil, folder: other.path), fresh: true)
        XCTAssertFalse(center.hasLiveClaudeSession(workbenchID: 9, workTree: folder.path))
    }

    func testSymlinkedSpellingsOfOneFolderMatch() throws {
        let real = URL(fileURLWithPath: "/private/tmp/wt-term-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: real.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }
        let viaTmp = "/tmp/" + real.lastPathComponent
        let center = makeCenter()
        center.start(try row(project: nil, folder: viaTmp + "/sub"), fresh: true)
        XCTAssertTrue(center.hasLiveClaudeSession(workbenchID: 9, workTree: real.path))
        XCTAssertTrue(center.hasLiveClaudeSession(workbenchID: 9, workTree: viaTmp))
    }

    func testASiblingSharingANamePrefixDoesNotCount() throws {
        let b = try dir("b")
        let bc = try dir("bc")
        let center = makeCenter()
        center.start(try row(project: nil, folder: bc.path), fresh: true)
        XCTAssertFalse(center.hasLiveClaudeSession(workbenchID: 9, workTree: b.path))
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

    func testAKeyboardFocusRequestIsForTheLatestSessionAsked() {
        let center = makeCenter()
        XCTAssertNil(center.keyboardFocusSerial(for: 1))
        center.requestKeyboardFocus(1)
        let first = center.keyboardFocusSerial(for: 1)
        XCTAssertNotNil(first)
        center.requestKeyboardFocus(1)
        XCTAssertNotEqual(center.keyboardFocusSerial(for: 1), first, "asked again: a new serial the host honours again")
        center.requestKeyboardFocus(2)
        XCTAssertNil(center.keyboardFocusSerial(for: 1), "only the latest request counts")
        XCTAssertNotNil(center.keyboardFocusSerial(for: 2))
    }

    /// The active session is the most recently focused live claude session
    /// of the project — never a shell, never another project's session.
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

    // MARK: - sendPrompt (the paste step of submitPrompt)

    func testARunningSessionGetsOneBracketedPasteWithNoEnter() throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)
        let line = OwnerAskPrompt.line(id: 7, kind: .question, answer: OwnerAskAnswer())
        XCTAssertEqual(center.sendPrompt(line, sessionID: s.id), .sent)
        XCTAssertEqual(sessions[0].inputs, [
            [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] + Array(line.utf8) + [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        ])
        XCTAssertFalse(sessions[0].inputs[0].contains(0x0D), "the paste step never presses Return; submitPrompt decides")
        XCTAssertFalse(center.clipboardHints.contains(s.id))
    }

    /// PROJ-12 (amended 2026-10-04, board #379): an answer's line is one
    /// bracketed paste — a line break or control character is dropped — and
    /// then one Return as a write of its own, after the pause.
    func testAnAnswerLineIsPastedAsOneLineThenSubmittedWithItsOwnReturn() async throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)
        let line = OwnerAskPrompt.line(id: 7, kind: .question, answer: OwnerAskAnswer())
        let delivery = await center.submitPrompt(line + "\r\n\u{1B}more", sessionID: s.id, keepingLineBreaks: false,
                                                 delay: TerminalCenter.answerSubmitDelay) { true }
        XCTAssertEqual(delivery, .submitted)
        XCTAssertEqual(sessions[0].inputs, [bracketedPasteBytes(line + "more"), [0x0D]])
        XCTAssertEqual(slept, TerminalCenter.answerSubmitDelay, "an answer's longer pause")
        XCTAssertEqual(inputsAtSleep, [[bracketedPasteBytes(line + "more")]], "the Return comes strictly after the pause")
    }

    /// Board #379: the owner's text typed since their last Return is a
    /// draft a Return would submit, so `submitPrompt` only pastes over it;
    /// keys answering a permission dialog are not a draft; a restart clears it.
    func testOverTheOwnersDraftSubmitPromptOnlyPastes() async throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)
        sessions[0].onOwnerInput?(Array("half".utf8))
        let overDraft = await center.submitPrompt("x", sessionID: s.id) { true }
        XCTAssertEqual(overDraft, .pasted)
        XCTAssertEqual(sessions[0].inputs, [bracketedPasteBytes("x")])
        XCTAssertEqual(slept, .zero, "no pause: no Return to wait for")

        sessions[0].onOwnerInput?(Array("more\r".utf8))
        center.inputAnswersDialog = { _ in true }
        sessions[0].onOwnerInput?(Array("2".utf8))
        center.inputAnswersDialog = { _ in false }
        let clean = await center.submitPrompt("y", sessionID: s.id) { true }
        XCTAssertEqual(clean, .submitted)

        sessions[0].onOwnerInput?(Array("z".utf8))
        sessions[0].exit(0)
        center.start(s, fresh: false)
        let restarted = await center.submitPrompt("w", sessionID: s.id) { true }
        XCTAssertEqual(restarted, .submitted, "a new run starts with an empty prompt")
    }

    /// Board #379 (PROJ-12): the owner typing during the pause leaves a
    /// draft the Return would submit with the line — re-checked after it.
    func testTheOwnerTypingDuringThePauseStopsTheReturn() async throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)
        onSleep = { [weak self] in self?.sessions[0].onOwnerInput?(Array("a".utf8)) }

        let delivery = await center.submitPrompt("x", sessionID: s.id) { true }

        XCTAssertEqual(delivery, .pasted)
        XCTAssertEqual(slept, TerminalCenter.submitDelay, "the draft came during the pause")
        XCTAssertEqual(sessions[0].inputs, [bracketedPasteBytes("x")], "no Return over it")
    }

    /// Board #388: the owner's own Return during the pause sent the line
    /// (with whatever they typed before it), so no second Return goes into
    /// the empty prompt and no bar asks for one; text they type after it
    /// is their own draft. A Return into a permission dialog sends nothing
    /// of the line and keeps the app's Return.
    func testTheOwnersReturnDuringThePauseSkipsOurs() async throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)
        for (input, name) in [([UInt8(0x0D)], "a bare Return"), (Array("and this\r".utf8), "text, then Return")] {
            onSleep = { [weak self] in self?.sessions[0].onOwnerInput?(input) }
            let before = sessions[0].inputs.count

            let delivery = await center.submitPrompt("x", sessionID: s.id) { true }

            XCTAssertEqual(delivery, .submitted, name)
            XCTAssertEqual(Array(sessions[0].inputs.dropFirst(before)), [bracketedPasteBytes("x")], "\(name): no Return of ours")
            XCTAssertFalse(center.pasteHints.contains(s.id), name)
            XCTAssertFalse(center.promptDrafts.contains(s.id), name)
        }

        onSleep = { [weak self] in
            self?.sessions[0].onOwnerInput?([0x0D])
            self?.sessions[0].onOwnerInput?(Array("next".utf8))
        }
        let thenTyped = await center.submitPrompt("y", sessionID: s.id) { true }
        XCTAssertEqual(thenTyped, .submitted)
        XCTAssertFalse(sessions[0].inputs.contains([0x0D]))
        XCTAssertFalse(center.pasteHints.contains(s.id), "the line went; the draft is the owner's own")
        XCTAssertTrue(center.promptDrafts.contains(s.id), "a later Return of ours would submit it")

        sessions[0].onOwnerInput?([0x0D])
        center.inputAnswersDialog = { _ in true }
        onSleep = { [weak self] in
            self?.sessions[0].onOwnerInput?([0x0D])
            center.inputAnswersDialog = { _ in false }
        }
        let intoDialog = await center.submitPrompt("z", sessionID: s.id) { true }
        XCTAssertEqual(intoDialog, .submitted)
        XCTAssertEqual(sessions[0].inputs.last, [0x0D], "a key into the dialog left the Return to us")
    }

    /// PROJ-12: a line the app left without its Return is still in the
    /// prompt, so the next line is only pasted after it — two lines never
    /// go as one message. Keys into a permission dialog leave it there; the
    /// owner's submitting Return or a restart empties the prompt.
    func testALineLeftWithoutItsReturnKeepsTheNextFromSubmittingIt() async throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)
        let left = await center.submitPrompt("a", sessionID: s.id) { false }
        XCTAssertEqual(left, .pasted)

        center.inputAnswersDialog = { _ in true }
        sessions[0].onOwnerInput?([0x0D])
        center.inputAnswersDialog = { _ in false }
        let next = await center.submitPrompt("b", sessionID: s.id) { true }
        XCTAssertEqual(next, .pasted, "the dialog's Return did not submit the prompt")
        XCTAssertFalse(sessions[0].inputs.contains([0x0D]))

        sessions[0].onOwnerInput?([0x0D])
        let afterReturn = await center.submitPrompt("c", sessionID: s.id) { true }
        XCTAssertEqual(afterReturn, .submitted)

        _ = await center.submitPrompt("d", sessionID: s.id) { false }
        sessions[0].exit(0)
        center.start(s, fresh: false)
        let restarted = await center.submitPrompt("e", sessionID: s.id) { true }
        XCTAssertEqual(restarted, .submitted, "a new run starts with an empty prompt")
    }

    /// PROJ-12: Claude Code's line-break keys end with CR or LF but do not
    /// submit — the owner's multi-line draft stays, so no Return follows.
    func testClaudeCodeLineBreakKeysLeaveTheDraft() async throws {
        let shapes: [(String, [[UInt8]])] = [
            ("Option+Return (ESC CR)", [Array("fix".utf8), [0x1B, 0x0D]]),
            ("backslash, then Return", [Array("fix\\".utf8), [0x0D]]),
            ("backslash and Return in one chunk", [Array("fix\\\r".utf8)]),
            ("Ctrl+J (LF)", [Array("fix".utf8), [0x0A]]),
            ("Shift+Return, kitty protocol", [Array("fix".utf8), Array("\u{1B}[13;2u".utf8)]),
            ("Shift+Return, modifyOtherKeys", [Array("fix".utf8), Array("\u{1B}[27;2;13~".utf8)]),
            ("a pasted backslash, then Return", [Array("\u{1B}[200~fix\\\u{1B}[201~".utf8), [0x0D]]),
            ("backslash, cursor keys, then Return", [Array("fix\\".utf8), Array("\u{1B}[D\u{1B}[C".utf8), [0x0D]]),
            ("backslash, an SS3 cursor key and Return in one chunk", [Array("fix\\\u{1B}OD\r".utf8)])
        ]
        for (name, chunks) in shapes {
            sessions = []
            let center = makeCenter()
            let s = try row()
            center.start(s, fresh: true)
            for chunk in chunks { sessions[0].onOwnerInput?(chunk) }
            let delivery = await center.submitPrompt("x", sessionID: s.id) { true }
            XCTAssertEqual(delivery, .pasted, name)
            XCTAssertFalse(sessions[0].inputs.contains([0x0D]), name)
        }

        sessions = []
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)
        sessions[0].onOwnerInput?(Array("fix\r".utf8))
        let submitted = await center.submitPrompt("x", sessionID: s.id) { true }
        XCTAssertEqual(submitted, .submitted, "a plain Return submits the draft")

        sessions[0].onOwnerInput?(Array("a\\".utf8))
        sessions[0].onOwnerInput?(Array("b".utf8))
        sessions[0].onOwnerInput?([0x0D])
        let afterText = await center.submitPrompt("y", sessionID: s.id) { true }
        XCTAssertEqual(afterText, .submitted, "a backslash followed by text no longer escapes the Return")
    }

    /// PROJ-12: after a failed state read the app does not know whether a
    /// permission prompt is on screen — no Return.
    func testAFailedRefreshAfterThePauseStopsTheReturn() async throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)

        let delivery = await center.submitPrompt("x", sessionID: s.id, refresh: { false }, submitIf: { true })

        XCTAssertEqual(delivery, .pasted)
        XCTAssertEqual(sessions[0].inputs, [bracketedPasteBytes("x")])
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

    // MARK: - An ask's answer hint (boards #364, #379)

    func testTheAnswerHintGoesWithTheOwnersInputDismissTheNextDeliveryOrTheExit() throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)

        center.showAnswerHint(.typed, sessionID: s.id)
        XCTAssertEqual(center.answerHints[s.id], .typed)
        sessions[0].onOwnerInput?(Array("y".utf8))
        XCTAssertNil(center.answerHints[s.id], "the owner's next input")

        center.showAnswerHint(.typed, sessionID: s.id)
        center.dismissClipboardHint(sessionID: s.id)
        XCTAssertNil(center.answerHints[s.id], "Dismiss")

        center.showAnswerHint(.typed, sessionID: s.id)
        XCTAssertEqual(center.sendPrompt("next", sessionID: s.id), .sent)
        XCTAssertNil(center.answerHints[s.id], "the next delivery")

        center.showAnswerHint(.typed, sessionID: s.id)
        sessions[0].exit(0)
        XCTAssertNil(center.answerHints[s.id], "the process exit")
    }

    /// A copied answer's hint walks the owner through it: the paste turns
    /// it into "press Return", the next input clears it.
    func testACopiedAnswerHintTurnsIntoPressReturnOnThePaste() throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)
        center.showAnswerHint(.copied, sessionID: s.id)

        sessions[0].onOwnerInput?(Array("y".utf8))
        XCTAssertEqual(center.answerHints[s.id], .typed)
        sessions[0].onOwnerInput?(Array("y".utf8))
        XCTAssertNil(center.answerHints[s.id])
    }

    /// Keys into a permission dialog are not the owner's next prompt input:
    /// a typed answer's "press Return" stays — the line is still unsent.
    func testATypedAnswerHintStaysThroughKeysIntoAPermissionDialog() throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)
        center.showAnswerHint(.typed, sessionID: s.id)

        center.inputAnswersDialog = { _ in true }
        sessions[0].onOwnerInput?(Array("1".utf8))
        XCTAssertEqual(center.answerHints[s.id], .typed)

        center.inputAnswersDialog = { _ in false }
        sessions[0].onOwnerInput?([0x0D])
        XCTAssertNil(center.answerHints[s.id])
    }

    /// A held answer's hint stays through the owner's input — that input
    /// answers the permission prompt — until the line goes.
    func testAHeldAnswerHintStaysThroughTheOwnersInputUntilTheDelivery() throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)
        center.showAnswerHint(.held, sessionID: s.id)

        sessions[0].onOwnerInput?(Array("y".utf8))
        XCTAssertEqual(center.answerHints[s.id], .held)
        XCTAssertEqual(center.sendPrompt("x", sessionID: s.id), .sent)
        XCTAssertNil(center.answerHints[s.id])
    }

    /// The copied hint replaces the generic clipboard one; a session not
    /// running gets no hint.
    func testTheAnswerHintReplacesTheClipboardHintAndNeedsARunningSession() throws {
        let center = makeCenter()
        center.copyToClipboard = { _ in }
        let s = try row()
        center.showAnswerHint(.typed, sessionID: s.id)
        XCTAssertNil(center.answerHints[s.id], "not running")

        center.start(s, fresh: true)
        sessions[0].bracketedPasteMode = false
        XCTAssertEqual(center.sendPrompt("x", sessionID: s.id), .copied)
        center.showAnswerHint(.copied, sessionID: s.id)
        XCTAssertEqual(center.answerHints[s.id], .copied)
        XCTAssertFalse(center.clipboardHints.contains(s.id))

        center.dismissClipboardHint(sessionID: s.id)
        XCTAssertNil(center.answerHints[s.id])
    }

    func testClosingASessionForgetsItsAnswerHint() async throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)
        center.showAnswerHint(.typed, sessionID: s.id)

        await center.close(sessionID: s.id)

        XCTAssertNil(center.answerHints[s.id])
        XCTAssertNil(sessions[0].onOwnerInput, "a closed process reports no input")
    }

    // MARK: - Hand to Claude Code (spec 2026-10-02 §9.5)

    private func bracketedPasteBytes(_ text: String) -> [UInt8] {
        [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] + Array(text.utf8) + [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
    }

    /// The hand-off is pasted once, lines kept, then submitted with one
    /// Return after the pause — while the caller says the session may take
    /// it (idle at its prompt, ruling R52), asked before and after the pause.
    func testAHandOffIsPastedOnceThenSubmitted() async throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)
        let text = "From a Watchtower code question:\nAsked at a.go:3\n\nQuestion: why?"
        var asked = 0
        let delivery = await center.submitPrompt(text, sessionID: s.id) {
            asked += 1
            return true
        }
        XCTAssertEqual(delivery, .submitted)
        XCTAssertEqual(sessions[0].inputs, [bracketedPasteBytes(text), [0x0D]])
        XCTAssertEqual(slept, TerminalCenter.submitDelay)
        XCTAssertEqual(asked, 2, "checked before and after the pause")
        XCTAssertFalse(center.pasteHints.contains(s.id))
    }

    /// Ruling R52: a session that may not take a Return (working, or a
    /// state that changed during the pause) gets the paste only, and the
    /// pane says to press Return.
    func testAHandOffIsOnlyPastedWhenTheSessionMayNotTakeAReturn() async throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)
        let notIdle = await center.submitPrompt("x", sessionID: s.id) { false }
        XCTAssertEqual(notIdle, .pasted)
        XCTAssertEqual(sessions[0].inputs, [bracketedPasteBytes("x")])
        XCTAssertTrue(center.pasteHints.contains(s.id))

        sessions[0].onOwnerInput?([0x0D])
        var refreshed = false
        let changed = await center.submitPrompt("y", sessionID: s.id, refresh: {
            refreshed = true
            return true
        }, submitIf: { !refreshed })
        XCTAssertTrue(refreshed, "the caller refreshes before the second check")
        XCTAssertEqual(changed, .pasted)
        XCTAssertEqual(sessions[0].inputs, [bracketedPasteBytes("x"), bracketedPasteBytes("y")], "no Return after the state changed")
        center.dismissClipboardHint(sessionID: s.id)
        XCTAssertFalse(center.pasteHints.contains(s.id))
    }

    /// Board #380: a line pasted next to text not submitted marks the
    /// prompt shared; a relaunch or a close empties the prompt, so the
    /// mark (and a close's paste bar) goes with it.
    func testASharedPromptIsClearedOnRestartAndClose() async throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)
        _ = await center.submitPrompt("x", sessionID: s.id) { false }
        XCTAssertFalse(center.sharedPrompts.contains(s.id), "the prompt held nothing before")
        _ = await center.submitPrompt("y", sessionID: s.id) { true }
        XCTAssertTrue(center.sharedPrompts.contains(s.id))

        sessions[0].exit(0)
        center.start(s, fresh: true)
        XCTAssertFalse(center.sharedPrompts.contains(s.id), "a new run starts with an empty prompt")

        _ = await center.submitPrompt("x", sessionID: s.id) { false }
        _ = await center.submitPrompt("y", sessionID: s.id) { true }
        XCTAssertTrue(center.sharedPrompts.contains(s.id))
        await center.close(sessionID: s.id)
        XCTAssertFalse(center.sharedPrompts.contains(s.id))
        XCTAssertFalse(center.pasteHints.contains(s.id), "no paste bar outlives its session")
    }

    /// Board #387: a relaunch during the pause reuses the process object,
    /// yet the Return never goes into the new run, and the new run's prompt
    /// is empty — its first line is submitted.
    func testARelaunchDuringThePauseGetsNoReturn() async throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)
        onSleep = { [weak self, center] in
            guard let self else { return }
            sessions[0].exit(0)
            center.start(s, fresh: false)
        }

        let delivery = await center.submitPrompt("x", sessionID: s.id) { true }

        XCTAssertEqual(sessions.count, 1, "the relaunch reused the process")
        XCTAssertEqual(delivery, .noSession)
        XCTAssertEqual(sessions[0].inputs, [bracketedPasteBytes("x")], "no Return into the new run")
        onSleep = nil
        let next = await center.submitPrompt("y", sessionID: s.id) { true }
        XCTAssertEqual(next, .submitted)
    }

    /// Board #389: a line the last run left without its Return is gone with
    /// that run's prompt, so a restart drops its "press Return" bar along
    /// with the draft.
    func testARestartDropsTheLastRunsPasteBar() async throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)
        _ = await center.submitPrompt("x", sessionID: s.id) { false }
        XCTAssertTrue(center.pasteHints.contains(s.id))
        XCTAssertTrue(center.promptDrafts.contains(s.id))

        sessions[0].exit(0)
        center.start(s, fresh: false)

        XCTAssertFalse(center.pasteHints.contains(s.id), "a new run starts with no paste bar")
        XCTAssertFalse(center.promptDrafts.contains(s.id))
        let next = await center.submitPrompt("y", sessionID: s.id) { true }
        XCTAssertEqual(next, .submitted)
    }

    /// Without bracketed paste the text goes to the clipboard and nothing,
    /// not even Return, reaches the terminal.
    func testAHandOffWithoutBracketedPasteIsCopiedAndNotSubmitted() async throws {
        let center = makeCenter()
        var copied: [String] = []
        center.copyToClipboard = { copied.append($0) }
        let s = try row()
        center.start(s, fresh: true)
        sessions[0].bracketedPasteMode = false
        let delivery = await center.submitPrompt("a\nb", sessionID: s.id) { true }
        XCTAssertEqual(delivery, .copied)
        XCTAssertTrue(sessions[0].inputs.isEmpty)
        XCTAssertEqual(copied, ["a\nb"])
    }

    func testAHandOffToAnEndedSessionSendsNothing() async throws {
        let center = makeCenter()
        let s = try row()
        center.start(s, fresh: true)
        sessions[0].exit(0)
        let delivery = await center.submitPrompt("x", sessionID: s.id) { true }
        XCTAssertEqual(delivery, .noSession)
        XCTAssertTrue(sessions[0].inputs.isEmpty)
    }

    /// A workbench session's ⌘-clicked `path:line` reaches `onPathLink`
    /// with its workbench; a standalone terminal keeps SwiftTerm's handler.
    func testPathLinksAreWiredForWorkbenchSessionsOnly() throws {
        let center = makeCenter()
        var opened: [(Int64, TerminalPathLinks.Location)] = []
        center.onPathLink = { opened.append(($0, $1)) }
        let workbench = try row(project: 1)
        let standalone = try row(project: nil, kind: .shell)
        center.start(workbench, fresh: true)
        center.start(standalone, fresh: true)
        XCTAssertEqual(sessions[0].pathLinkFolder, folder.path)
        XCTAssertNil(sessions[1].pathLinkFolder)
        let location = TerminalPathLinks.Location(path: "a.go", line: 3, col: nil)
        sessions[0].openPathLink?(location)
        XCTAssertEqual(opened.map(\.0), [1])
        XCTAssertEqual(opened.map(\.1), [location])
    }

    /// F3: SwiftTerm's own handler gets only a URL the app-wide allowlist
    /// permits; a `file://` or path outside the folder opens nothing.
    func testTerminalLinksPassTheURLAllowlist() throws {
        let workbench = folder.path
        for link in ["smb://server/share", "x-apple.systempreferences:com.apple.preference.security",
                     "file:///etc/hosts", "/etc/hosts:1", "vnc://host"] {
            XCTAssertEqual(PalettedTerminalView.linkAction(for: link, folder: workbench, folderRealPath: nil), .none, link)
            XCTAssertEqual(PalettedTerminalView.linkAction(for: link, folder: nil, folderRealPath: nil), .none, "standalone: \(link)")
        }
        XCTAssertEqual(PalettedTerminalView.linkAction(for: "https://example.com/x", folder: workbench, folderRealPath: nil), .systemHandler)
        XCTAssertEqual(PalettedTerminalView.linkAction(for: "http://host:80", folder: nil, folderRealPath: nil), .systemHandler)
        try "x\n".write(to: folder.appendingPathComponent("a.go"), atomically: true, encoding: .utf8)
        XCTAssertEqual(PalettedTerminalView.linkAction(for: "a.go:3", folder: workbench, folderRealPath: nil),
                       .open(.init(path: "a.go", line: 3, col: nil)))
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

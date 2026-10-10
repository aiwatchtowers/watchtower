import XCTest
import AppKit
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The reads a center made, by the ids asked for.
private final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [[Int64]] = []
    var fail = false

    var reads: [[Int64]] { lock.withLock { asked } }

    func record(_ ids: [Int64]) throws {
        try lock.withLock {
            asked.append(ids)
            if fail { throw CancellationError() }
        }
    }
}

/// A clock a test moves by hand.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Records the session notices instead of posting them; AppState tests
/// pass one to `initWorkbenches` so no test reaches `UNUserNotificationCenter`.
@MainActor
final class RecordingSessionNotifier: SessionAgentNotifying {
    private(set) var posted: [SessionAgentNoticePolicy.Notice] = []
    private(set) var withdrawn: [String] = []
    private(set) var withdrawAllCount = 0

    func sendSessionAgentNotice(_ notice: SessionAgentNoticePolicy.Notice) { posted.append(notice) }
    func withdrawSessionAgentNotice(identifier: String) { withdrawn.append(identifier) }
    func withdrawAllSessionAgentNotices() { withdrawAllCount += 1 }
}

@MainActor
final class SessionAgentStateCenterTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var folder: URL!
    private var processes: [FakeTerminalSession] = []
    private var terminals: TerminalCenter!
    private var log: ReadLog!
    private var centers: [SessionAgentStateCenter] = []
    private var notifier: RecordingSessionNotifier!
    private var defaults: UserDefaults!
    private var appActive = false
    private var activations: NotificationCenter!
    private let started = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt agent \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        processes = []
        log = ReadLog()
        centers = []
        notifier = RecordingSessionNotifier()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "SessionAgentStateCenterTests-\(UUID().uuidString)"))
        appActive = false
        activations = NotificationCenter()
        terminals = TerminalCenter { [weak self] in
            let process = FakeTerminalSession(pid: 0)
            self?.processes.append(process)
            return process
        }
        terminals.shell = { "/bin/zsh" }
        terminals.transcriptExists = { _ in true }
        terminals.now = { [started] in started }
    }

    override func tearDown() {
        // No loop outlives its test.
        centers.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeCenter(
        interval: Duration = .milliseconds(20),
        read: SessionAgentStateCenter.Reader? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        probeRunner: (any CLIRunnerProtocol)? = nil
    ) -> SessionAgentStateCenter {
        let reader: SessionAgentStateCenter.Reader = read ?? { [pool, log] ids in
            try log?.record(ids)
            guard let pool else { return [] }
            return try await pool.read { try TerminalSessionQueries.fetchAgentStates($0, liveIDs: ids) }
        }
        let center = SessionAgentStateCenter(
            dbPool: pool, terminalCenter: terminals, interval: interval, notifier: notifier, defaults: defaults,
            notificationCenter: activations, read: reader, clock: clock, probeRunner: probeRunner
        )
        center.isAppActive = { [weak self] in self?.appActive ?? true }
        centers.append(center)
        return center
    }

    private func session(_ kind: TerminalSession.Kind = .claude, title: String = "Release work") async throws
        -> TerminalSession {
        let dir = folder.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return try await pool.write { db in
            let project = try TestDatabase.insertWorkbench(db, name: "acme", folder: dir)
            return try TerminalSessionQueries.create(db, .init(
                projectID: project, kind: kind, title: title, folderPath: dir,
                claudeSessionID: kind == .claude ? UUID().uuidString.lowercased() : nil
            ))
        }
    }

    private func stamp(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: started.addingTimeInterval(offset))
    }

    /// What the hook does, from another connection (in the app, another
    /// process), with the guards of Go's `db.SetTerminalAgentState`: the
    /// row's own conversation, a changed state, a later stamp. Returns
    /// whether it wrote.
    @discardableResult
    private func hookWrites(_ id: Int64, _ state: String, at offset: TimeInterval) throws -> Bool {
        let other = try DatabaseQueue(path: path)
        return try other.write { db in
            try db.execute(
                sql: """
                    UPDATE terminal_sessions SET agent_state = ?, agent_state_at = ?
                    WHERE id = ? AND kind = 'claude' AND claude_session_id IS NOT NULL
                      AND agent_state IS NOT ?
                      AND (agent_state_at IS NULL OR agent_state_at < ?)
                    """,
                arguments: [state, stamp(offset), id, state, stamp(offset)]
            )
            return db.changesCount > 0
        }
    }

    /// The SessionStart hook of a launch or a resume, with the guards of Go's
    /// `db.ClearTerminalAgentState`.
    private func sessionStartClears(_ id: Int64, at offset: TimeInterval) throws {
        let other = try DatabaseQueue(path: path)
        try other.write { db in
            try db.execute(
                sql: """
                    UPDATE terminal_sessions SET agent_state = NULL, agent_state_at = ?
                    WHERE id = ? AND kind = 'claude' AND agent_state IS NOT NULL
                      AND (agent_state_at IS NULL OR agent_state_at < ?)
                    """,
                arguments: [stamp(offset), id, stamp(offset)]
            )
        }
    }

    private func eventually(
        _ what: String, within timeout: Duration = .seconds(3), _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return XCTFail("timed out: \(what)") }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Banners a previous process left name dead runs: removed on start
    /// (once) and on quit.
    func testStartAndQuitRemoveLeftoverBanners() {
        let center = makeCenter()
        center.start()
        center.start()
        XCTAssertEqual(notifier.withdrawAllCount, 1)
        center.withdrawAllNotices()
        XCTAssertEqual(notifier.withdrawAllCount, 2)
    }

    /// The 1 s poll stays live-only: a live shell has no hooks to read.
    func testNoLiveClaudeSessionStartsNoPoll() async throws {
        let center = makeCenter()
        center.start()
        let shell = try await session(.shell)
        terminals.start(shell, fresh: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(log.reads, [], "nothing is read without a trigger")
        XCTAssertFalse(center.isPolling)
        XCTAssertEqual(center.statuses, [:])
    }

    /// A closed session changes only through its asks or a finish, so app
    /// activation, the tab appearing and an answer each read once — with no
    /// session live and no loop.
    func testActivationAndTheTabAppearingReadWithNoLiveSession() async throws {
        let center = makeCenter()
        center.start()
        let row = try await session()
        try await pool.write { db in
            try db.execute(sql: "UPDATE terminal_sessions SET finished_at = '2026-10-03T12:00:00.000Z' WHERE id = ?",
                           arguments: [row.id])
        }
        activations.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await eventually("app activation reads") { log.reads == [[]] }
        XCTAssertEqual(center.statuses[row.id]?.state, SessionSwitcherPresentation.State(kind: .finished, live: false),
                       "a closed finished session: a blue ring")
        XCTAssertFalse(center.isPolling, "a refresh starts no loop")

        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults, terminalCenter: terminals,
                                      agentStates: center)
        await vm.tabAppeared()
        await eventually("the Workbench tab appearing reads") { log.reads.count == 2 }
        center.stop()
        activations.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(log.reads.count, 2, "a stopped center no longer follows activation")
    }

    /// The owner answers a closed session's only ask: its orange ring turns
    /// grey right away, with no session live to poll.
    func testAClosedSessionsAskRingTurnsGreyWhenTheAskIsAnswered() async throws {
        let center = makeCenter()
        center.start()
        let row = try await session()
        let projectID = try XCTUnwrap(row.projectID)
        let questions = #"{"questions":[{"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}]}"#
        let askID = try await pool.write { db in
            try TestDatabase.insertOwnerAsk(db, projectID: projectID, sessionID: row.id, payload: questions)
        }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults, terminalCenter: terminals,
                                      agentStates: center)
        await center.poll()
        let waiting = vm.sessionState(row)
        XCTAssertEqual(
            waiting, SessionSwitcherPresentation.State(kind: .waitingOnAsk, live: false, openAsks: 1, oldestAskID: askID)
        )
        XCTAssertEqual(SessionStatePresentation.color(for: waiting), .orange)
        XCTAssertTrue(SessionStatePresentation.isRing(waiting))
        XCTAssertEqual(SessionStatePresentation.caption(for: waiting), "Waiting for you · ask #\(askID)")

        await vm.asks.load(projectID: projectID)
        let ask = try XCTUnwrap(vm.asks.openAsks[projectID]?.first { $0.id == askID })
        vm.asks.drafts.update(askID) { $0.picks["a"] = .init(labels: ["Yes"]) }
        let reads = log.reads.count
        let delivery = await vm.asks.answer(ask)
        XCTAssertEqual(delivery, .noSession)

        XCTAssertEqual(log.reads.count, reads + 1, "the answer read the states once")
        XCTAssertEqual(vm.sessionState(row), .notStarted, "a grey ring, without waiting for a poll")
        XCTAssertFalse(center.isPolling)
    }

    /// PROJ-12 (amended 2026-10-04, board #379), wired through the
    /// stored states: an answer to a session at a permission prompt is held,
    /// and goes — pasted, then Return — on the read that shows the prompt
    /// answered.
    func testAnAnswerHeldAtAPermissionPromptGoesOnTheReadThatShowsItAnswered() async throws {
        let center = makeCenter(interval: .seconds(60))
        center.start()
        let row = try await session()
        let projectID = try XCTUnwrap(row.projectID)
        let questions = #"{"questions":[{"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}]}"#
        let askID = try await pool.write { db in
            try TestDatabase.insertOwnerAsk(db, projectID: projectID, sessionID: row.id, payload: questions)
        }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults, terminalCenter: terminals,
                                      agentStates: center)
        terminals.start(row, fresh: true)
        let process = try XCTUnwrap(processes.last)
        try hookWrites(row.id, "approval", at: 1)
        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state.kind, .needsApproval)

        await vm.asks.load(projectID: projectID)
        let ask = try XCTUnwrap(vm.asks.openAsks[projectID]?.first { $0.id == askID })
        vm.asks.drafts.update(askID) { $0.picks["a"] = .init(labels: ["Yes"]) }
        let delivery = await vm.asks.answer(ask)
        XCTAssertEqual(delivery, .held)
        XCTAssertTrue(process.inputs.isEmpty)

        try hookWrites(row.id, "working", at: 2)
        await center.poll()

        await eventually("the held line goes") { process.inputs.count == 2 }
        XCTAssertEqual(process.inputs.last, [0x0D])
        XCTAssertEqual(vm.asks.answerNotices[askID]?.text, OwnerAsksViewModel.answerSentNote)
    }

    /// `onRead` fires on every read that succeeded, changed or not, and on
    /// no failed one.
    func testOnReadFiresOnEverySuccessfulReadOnly() async throws {
        let center = makeCenter(interval: .seconds(60))
        var reads = 0
        center.onRead = { reads += 1 }
        _ = try await session()
        let first = await center.poll()
        let unchanged = await center.poll()
        XCTAssertTrue(first && unchanged)
        XCTAssertEqual(reads, 2, "an unchanged read too")
        log.fail = true
        let failed = await center.poll()
        XCTAssertFalse(failed)
        XCTAssertEqual(reads, 2)
    }

    /// `onChange` fires on a change of the statuses only.
    func testOnChangeFiresOnlyWhenTheStatusesChange() async throws {
        let center = makeCenter(interval: .seconds(60))
        var changes = 0
        center.onChange = { changes += 1 }
        let row = try await session()
        await center.poll()
        XCTAssertEqual(changes, 1, "the first read")
        await center.poll()
        XCTAssertEqual(changes, 1, "an unchanged read")
        terminals.start(row, fresh: true)
        try hookWrites(row.id, "working", at: 1)
        await center.poll()
        XCTAssertEqual(changes, 2)
    }

    func testPollStartsAndStopsWithLiveness() async throws {
        let center = makeCenter()
        center.start()
        XCTAssertFalse(center.isPolling)
        let row = try await session()
        terminals.start(row, fresh: true)
        await eventually("the loop starts with a live claude session") { center.isPolling }
        await eventually("it reads the live session") { log.reads.contains([row.id]) }
        processes.last?.exit(0)
        await eventually("the loop stops with the last session") { !center.isPolling }
        let count = log.reads.count
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(log.reads.count, count, "no reads once nothing is live")
    }

    func testAHookWriteIsPublishedWithinATick() async throws {
        let center = makeCenter()
        center.start()
        let row = try await session()
        terminals.start(row, fresh: true)
        await eventually("the first poll ran") { center.statuses[row.id]?.state == .live(.running) }
        try hookWrites(row.id, "waiting", at: 1)
        await eventually("the turn end shows", within: .seconds(1)) {
            center.statuses[row.id]?.state == .live(.stopped)
        }
        XCTAssertEqual(center.statuses[row.id]?.title, "Release work")
        XCTAssertEqual(center.statuses[row.id]?.at, stamp(1))
        try hookWrites(row.id, "approval", at: 2)
        await eventually("approval shows") { center.statuses[row.id]?.state == .live(.needsApproval) }
    }

    func testAnUnchangedReadDoesNotReassignStatuses() async throws {
        let center = makeCenter()
        let row = try await session()
        terminals.start(row, fresh: true)
        try hookWrites(row.id, "working", at: 1)
        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state, .live(.working))
        var changed = false
        withObservationTracking { _ = center.statuses } onChange: { changed = true }
        await center.poll()
        await center.poll()
        XCTAssertFalse(changed, "an unchanged read re-renders nothing")
        try hookWrites(row.id, "waiting", at: 2)
        await center.poll()
        XCTAssertTrue(changed)
    }

    /// Decision 9 end to end: a state the previous run wrote is not shown
    /// after a Restart; the new run's first hook is.
    func testAStateFromBeforeARestartIsIgnoredAfterIt() async throws {
        let center = makeCenter()
        let row = try await session()
        terminals.start(row, fresh: true)
        try hookWrites(row.id, "waiting", at: 1)
        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state, .live(.stopped))

        processes.last?.exit(0)
        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state, .notStarted, "an exited session's hook state is gone")

        terminals.now = { [started] in started.addingTimeInterval(10) }
        terminals.start(row, fresh: false)
        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state, .live(.running), "the earlier run's waiting is not trusted")
        try hookWrites(row.id, "working", at: 11)
        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state, .live(.working))
    }

    /// A relaunch whose first state equals the previous run's last one:
    /// without the SessionStart clear the repeat is skipped and the old
    /// run's stamp is not trusted; with it the new run's state shows.
    func testTheSameStateInANewRunIsTrusted() async throws {
        let center = makeCenter()
        let row = try await session()
        terminals.start(row, fresh: true)
        XCTAssertTrue(try hookWrites(row.id, "waiting", at: 1))
        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state, .live(.stopped))
        processes.last?.exit(0)

        terminals.now = { [started] in started.addingTimeInterval(10) }
        terminals.start(row, fresh: false)
        try sessionStartClears(row.id, at: 10.5)
        XCTAssertTrue(try hookWrites(row.id, "waiting", at: 11), "the new run's waiting is not a repeat")
        XCTAssertFalse(try hookWrites(row.id, "working", at: 5), "a late hook of the previous run cannot land")
        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state, .live(.stopped))
        XCTAssertEqual(center.statuses[row.id]?.at, stamp(11))
    }

    /// A Restart between two polls, while another session keeps the loop
    /// going: the previous run's state goes at once, not on the next tick.
    func testARestartBetweenPollsDropsThePreviousRunsState() async throws {
        let center = makeCenter(interval: .seconds(3600))
        let first = try await session(title: "One")
        let second = try await session(title: "Two")
        terminals.start(first, fresh: true)
        terminals.start(second, fresh: true)
        try hookWrites(first.id, "waiting", at: 1)
        try hookWrites(second.id, "working", at: 1)
        // The loop's first poll is the only one within the test.
        center.start()
        await eventually("the first poll") { center.statuses[first.id]?.state == .live(.stopped) }
        XCTAssertEqual(log.reads.count, 1)

        processes.first?.exit(0)
        terminals.now = { [started] in started.addingTimeInterval(10) }
        terminals.start(first, fresh: false)

        await eventually("the previous run's waiting is dropped without a poll") {
            center.statuses[first.id]?.state == .live(.running)
        }
        XCTAssertEqual(center.statuses[second.id]?.state, .live(.working), "the other session keeps its state")
        XCTAssertEqual(log.reads.count, 1, "no poll ran")
    }

    /// An exit draws the finished session's blue ring at once, from the
    /// last read: a closed session changes in no other way.
    func testAnExitTurnsAFinishedDotIntoARingWithoutARead() async throws {
        let center = makeCenter(interval: .seconds(3600))
        let row = try await session()
        terminals.start(row, fresh: true)
        try hookWrites(row.id, "waiting", at: 1)
        let finishedAt = stamp(0.5)
        try await pool.write { db in
            try db.execute(sql: "UPDATE terminal_sessions SET finished_at = ?, finish_summary = 'Done' WHERE id = ?",
                           arguments: [finishedAt, row.id])
        }
        center.start()
        await eventually("the first poll") { center.statuses[row.id]?.state == .live(.finished) }
        processes.last?.exit(0)
        await eventually("a blue ring without a read") {
            center.statuses[row.id]?.state == SessionSwitcherPresentation.State(kind: .finished, live: false)
        }
        XCTAssertEqual(log.reads.count, 1)
        XCTAssertFalse(center.isPolling)
    }

    func testExitTurnsTheStatusNotLiveWhileOtherSessionsRun() async throws {
        let center = makeCenter()
        let first = try await session(title: "One")
        let second = try await session(title: "Two")
        terminals.start(first, fresh: true)
        terminals.start(second, fresh: true)
        try hookWrites(first.id, "waiting", at: 1)
        try hookWrites(second.id, "working", at: 1)
        await center.poll()
        XCTAssertEqual(Set(center.statuses.keys), [first.id, second.id])
        processes.first?.exit(0)
        await center.poll()
        XCTAssertEqual(center.statuses[first.id]?.state, .notStarted, "a closed workbench session keeps a status")
        XCTAssertEqual(center.statuses[second.id]?.state, .live(.working))
        XCTAssertEqual(log.reads.last, [second.id], "the live ids are what the read is given")
    }

    func testAReadFailureKeepsTheLastMapOfLiveSessions() async throws {
        let center = makeCenter()
        let row = try await session()
        terminals.start(row, fresh: true)
        try hookWrites(row.id, "approval", at: 1)
        await center.poll()
        log.fail = true
        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state, .live(.needsApproval), "a failed read keeps the last map")
        processes.last?.exit(0)
        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state, .notStarted, "the last read, resolved for what is live now")
    }

    func testStartedAtIsSetOnStartAndReplacedOnRelaunch() async throws {
        let row = try await session()
        terminals.start(row, fresh: true)
        XCTAssertEqual(terminals.startedAt[row.id], started)
        XCTAssertEqual(terminals.liveClaudeIDs, [row.id])
        processes.last?.exit(0)
        XCTAssertEqual(terminals.liveClaudeIDs, [])
        terminals.now = { [started] in started.addingTimeInterval(60) }
        terminals.start(row, fresh: false)
        XCTAssertEqual(terminals.startedAt[row.id], started.addingTimeInterval(60))
        await terminals.close(sessionID: row.id)
        XCTAssertNil(terminals.startedAt[row.id], "forgotten with the session")
    }

    /// House rule: the poll lives on AppState, so a state change is still
    /// published while the owner is on another tab.
    func testTheCenterLivesOnAppStateAndPollsWithTheTabNotShown() async throws {
        let appState = AppState()
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.terminalCenter.shell = { "/bin/zsh" }
        appState.terminalCenter.transcriptExists = { _ in true }
        appState.terminalCenter.now = { [started] in started }
        let sessionNotifier = RecordingSessionNotifier()
        appState.initWorkbenches(
            dbPool: pool, cliRunner: FakeCLIRunner(), notifier: RecordingWorkbenchNotifier(),
            sessionNotifier: sessionNotifier
        )
        defer {
            appState.sessionAgentStateCenter?.stop()
            appState.workbenchNotificationCenter?.stop()
        }
        let center = try XCTUnwrap(appState.sessionAgentStateCenter)
        center.isAppActive = { false }
        let vm = try XCTUnwrap(appState.workbenchesViewModel)
        XCTAssertTrue(vm.agentStates === center, "the VM reads the AppState-owned center")

        appState.selectedDestination = .workbench
        let row = try await session()
        appState.terminalCenter.start(row, fresh: true)
        appState.selectedDestination = .inbox
        try hookWrites(row.id, "waiting", at: 1)
        await eventually("published with the Workbench tab not shown") {
            center.statuses[row.id]?.state == .live(.stopped)
        }
        XCTAssertEqual(sessionNotifier.posted.map(\.sessionID), [row.id], "announced with the tab not shown")
        appState.selectedDestination = .workbench
        XCTAssertEqual(vm.sessionState(row), .live(.stopped))
    }

    // MARK: - Notices

    func testATransitionWithTheAppInactivePostsOneNotice() async throws {
        let center = makeCenter()
        let row = try await session(title: "Release work")
        terminals.start(row, fresh: true)
        await center.poll()
        try hookWrites(row.id, "waiting", at: 1)
        await center.poll()
        await center.poll()
        XCTAssertEqual(notifier.posted, [.init(sessionID: row.id, workbenchID: try XCTUnwrap(row.projectID),
                                               title: "Release work stopped", body: "acme")])
        XCTAssertEqual(notifier.posted.first?.identifier, "workbench-session-\(row.id)")
        try hookWrites(row.id, "approval", at: 2)
        await center.poll()
        XCTAssertEqual(notifier.posted.map(\.title).last, "Release work needs approval")
        XCTAssertEqual(notifier.posted.count, 2)
    }

    func testTheAppActivePostsNothingAndDoesNotReplayLater() async throws {
        appActive = true
        let center = makeCenter()
        let row = try await session()
        terminals.start(row, fresh: true)
        try hookWrites(row.id, "waiting", at: 1)
        await center.poll()
        appActive = false
        await center.poll()
        XCTAssertEqual(notifier.posted, [], "the transition seen while active is not replayed")
        try hookWrites(row.id, "approval", at: 2)
        await center.poll()
        XCTAssertEqual(notifier.posted.count, 1, "the next transition is announced")
    }

    func testNotificationsOffOrQuietHoursPostNothing() async throws {
        for (key, value) in [(WorkbenchNotificationCenter.enabledKey, false), ("quietHoursEnabled", true)] {
            defaults.set(value, forKey: key)
            let center = makeCenter()
            let row = try await session()
            terminals.start(row, fresh: true)
            try hookWrites(row.id, "waiting", at: 1)
            await center.poll()
            XCTAssertEqual(notifier.posted, [], "\(key)")
            defaults.removeObject(forKey: key)
            center.stop()
        }
    }

    func testBackToWorkingWithdrawsTheBanner() async throws {
        let center = makeCenter()
        let row = try await session()
        terminals.start(row, fresh: true)
        try hookWrites(row.id, "waiting", at: 1)
        await center.poll()
        try hookWrites(row.id, "working", at: 2)
        await center.poll()
        XCTAssertEqual(notifier.withdrawn, ["workbench-session-\(row.id)"])
        try hookWrites(row.id, "waiting", at: 3)
        await center.poll()
        processes.last?.exit(0)
        await center.poll()
        XCTAssertEqual(notifier.posted.count, 2)
        XCTAssertEqual(notifier.withdrawn.count, 2, "a session that stops takes its banner away")
    }

    /// #411: a count lowered to zero ends on the center's clock, with no
    /// write — the same row read again past the grace publishes Stopped and
    /// announces it once.
    func testBackgroundEndsOnTheClockWithoutAWrite() async throws {
        let row = try await session(title: "Release work")
        terminals.start(row, fresh: true)
        let reported = started.addingTimeInterval(2)
        let stored = SessionAgentStateRow(
            id: row.id, projectID: row.projectID, title: "Release work", agentState: "waiting",
            agentStateAt: stamp(1), workbenchName: "acme", agentBackground: 0, agentBackgroundAt: stamp(2)
        )
        let clock = ManualClock(reported.addingTimeInterval(60))
        let center = makeCenter(interval: .seconds(60), read: { _ in [stored] }, clock: { clock.now })
        var changes = 0
        center.onChange = { changes += 1 }
        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state, .live(.background))
        XCTAssertEqual(notifier.posted, [], "background is not announced")
        changes = 0

        clock.now = reported.addingTimeInterval(121)
        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state, .live(.stopped))
        XCTAssertEqual(center.statuses[row.id]?.at, stamp(1))
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(notifier.posted, [.init(sessionID: row.id, workbenchID: try XCTUnwrap(row.projectID),
                                               title: "Release work stopped", body: "acme")])
        await center.poll()
        XCTAssertEqual(notifier.posted.count, 1, "announced once")
    }

    /// The row a background test reads, which a fake Go write changes.
    private final class StoredRow: @unchecked Sendable {
        private let lock = NSLock()
        private var value: SessionAgentStateRow

        init(_ value: SessionAgentStateRow) { self.value = value }

        var row: SessionAgentStateRow {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private func backgroundRow(_ row: TerminalSession) -> SessionAgentStateRow {
        SessionAgentStateRow(
            id: row.id, projectID: row.projectID, title: "Release work", agentState: "waiting",
            agentStateAt: stamp(1), workbenchName: "acme", agentBackground: 2, agentBackgroundAt: stamp(2)
        )
    }

    /// #411 §10: a count silent for 30 minutes is probed; the CLI ends it
    /// (the only writer), the center reads the row again at once and
    /// announces Stopped once.
    func testAProbeThatEndsTheCountPostsOneStoppedNotice() async throws {
        let row = try await session(title: "Release work")
        terminals.start(row, fresh: true)
        let stored = StoredRow(backgroundRow(row))
        let runner = ScriptedProbeRunner {
            // What Go's compare-and-clear leaves.
            stored.row.agentBackground = nil
            return Data(ProbeAnswer.ran("idle", ended: true).utf8)
        }
        let clock = ManualClock(started.addingTimeInterval(2 + 31 * 60))
        let center = makeCenter(interval: .seconds(60), read: { _ in [stored.row] }, clock: { clock.now },
                                probeRunner: runner)
        await center.poll()
        await eventually("the probe ends the count and the center reads it") {
            center.statuses[row.id]?.state == .live(.stopped)
        }
        XCTAssertEqual(runner.invocations, [[
            "workbench", "session-probe", "--workbench", String(try XCTUnwrap(row.projectID)), "--session", String(row.id)
        ]])
        XCTAssertEqual(center.statuses[row.id]?.at, stamp(1))
        XCTAssertEqual(notifier.posted, [.init(sessionID: row.id, workbenchID: try XCTUnwrap(row.projectID),
                                               title: "Release work stopped", body: "acme")])
        clock.now = clock.now.addingTimeInterval(3600)
        await center.poll()
        XCTAssertEqual(notifier.posted.count, 1, "announced once")
        XCTAssertEqual(runner.invocations.count, 1, "no count, no probe")
    }

    /// #411 §10 (F24): two probes that cannot run show the count over —
    /// Stopped, one notice — while the row never changes; a new report
    /// brings Agents working back.
    func testTwoFailedProbesShowStoppedOnceWithoutAWrite() async throws {
        let row = try await session(title: "Release work")
        terminals.start(row, fresh: true)
        let stored = StoredRow(backgroundRow(row))
        let runner = ScriptedProbeRunner(json: ProbeAnswer.failed)
        let clock = ManualClock(started.addingTimeInterval(2 + 31 * 60))
        let center = makeCenter(interval: .seconds(60), read: { _ in [stored.row] }, clock: { clock.now },
                                probeRunner: runner)
        await center.poll()
        await eventually("the first probe runs") { runner.invocations.count == 1 }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(center.statuses[row.id]?.state, .live(.background, backgroundAgents: 2),
                       "one failed probe changes nothing")
        XCTAssertEqual(notifier.posted, [])

        clock.now = clock.now.addingTimeInterval(SessionBackgroundProber.retryAfter)
        await center.poll()
        await eventually("two failed probes show the count over") {
            center.statuses[row.id]?.state == .live(.stopped)
        }
        XCTAssertEqual(stored.row, backgroundRow(row), "nothing written")
        XCTAssertEqual(notifier.posted, [.init(sessionID: row.id, workbenchID: try XCTUnwrap(row.projectID),
                                               title: "Release work stopped", body: "acme")])
        clock.now = clock.now.addingTimeInterval(SessionBackgroundProber.retryAfter)
        await center.poll()
        await eventually("the probe is tried again") { runner.invocations.count == 3 }
        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state, .live(.stopped))
        XCTAssertEqual(notifier.posted.count, 1, "announced once")

        stored.row.agentBackgroundAt = stamp(clock.now.timeIntervalSince(started))
        await center.poll()
        XCTAssertEqual(center.statuses[row.id]?.state, .live(.background, backgroundAgents: 2),
                       "a new report is a new count")
    }

    // MARK: - Views

    func testThePanelRowShowsTheAgentStateOrTheAge() async throws {
        let created = try await session()
        let stampAgo = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-(5 * 60 + 3)))
        let session = try await pool.write { db in
            try db.execute(sql: "UPDATE terminal_sessions SET last_active_at = ? WHERE id = ?",
                           arguments: [stampAgo, created.id])
            return try XCTUnwrap(TerminalSessionQueries.fetch(db, id: created.id))
        }
        let id = session.id
        let status = SessionAgentStatus(sessionID: id, workbenchID: session.projectID, workbenchName: "acme",
                                        title: session.title, state: .live(.stopped), at: "t")
        let actions = SessionRowActions(open: { _ in }, rename: { _ in }, delete: { _ in })

        let waiting = SessionSwitcherPresentation.rows([session], liveIDs: [id], statuses: [id: status], now: Date())[0]
        let live = TerminalSessionRow(row: waiting, actions: actions)
        let label = try live.inspect().find(SessionStateLabel.self)
        XCTAssertNoThrow(try label.find(text: "Stopped"))
        XCTAssertEqual(try label.find(ViewType.Image.self).actualImage().name(), "pause.fill")
        XCTAssertEqual(try label.hStack().accessibilityLabel().string(), "Stopped", "the caption is read out")
        let dot = try live.inspect().find(SessionLiveDot.self)
        XCTAssertEqual(try dot.actualView().state, .live(.stopped))
        XCTAssertEqual(try dot.find(ViewType.Image.self).foregroundStyleShapeStyle(Color.self), .secondary)
        XCTAssertTrue(try dot.accessibilityHidden(), "VoiceOver hears the state once, from the label")

        let dead = SessionSwitcherPresentation.rows([session], liveIDs: [], statuses: [id: status], now: Date())[0]
        let idle = TerminalSessionRow(row: dead, actions: actions)
        XCTAssertNoThrow(try idle.inspect().find(text: "Not running · 5m"))
        XCTAssertNoThrow(try idle.inspect().find(viewWithAccessibilityLabel: "Not running · 5m"), "the age is read")
        XCTAssertThrowsError(try idle.inspect().find(text: "Stopped"))
        XCTAssertThrowsError(try idle.inspect().find(SessionStateLabel.self).find(ViewType.Image.self), "no glyph")
    }

    func testTheDotColourAndLabelPerState() throws {
        let expected: [(SessionSwitcherPresentation.State, Color, String, String)] = [
            (.live(.running), .green, "Running", "circle.fill"),
            (.live(.working), .green, "Working", "circle.fill"),
            (.live(.stopped), .secondary, "Stopped", "circle.fill"),
            (.live(.waitingOnAsk, openAsks: 1), .orange, "Waiting for you", "circle.fill"),
            (.live(.waitingOnAsk, openAsks: 2, oldestAskID: 12), .orange, "Waiting for you · ask #12 · 2 asks", "circle.fill"),
            (SessionSwitcherPresentation.State(kind: .waitingOnAsk, live: false, openAsks: 1, oldestAskID: 3), .orange,
             "Waiting for you · ask #3", "circle"),
            (SessionSwitcherPresentation.State(kind: .finished, live: false, openAsks: 1), .orange,
             "Finished · 1 ask open", "circle"),
            (.live(.needsApproval), .orange, "Needs approval", "circle.fill"),
            (.live(.failed, error: "rate_limit"), .red, "Error: rate limit", "circle.fill"),
            (.live(.finished), .blue, "Finished", "circle.fill"),
            (SessionSwitcherPresentation.State(kind: .finished, live: false), .blue, "Finished", "circle"),
            (.notStarted, .secondary, "Not running", "circle")
        ]
        for (state, color, label, symbol) in expected {
            let image = try SessionLiveDot(state: state).inspect().find(ViewType.Image.self)
            XCTAssertEqual(try image.foregroundStyleShapeStyle(Color.self), color, "\(state)")
            XCTAssertEqual(try image.actualImage().name(), symbol, "\(state)")
            XCTAssertNoThrow(try SessionLiveDot(state: state).inspect().find(viewWithAccessibilityLabel: label))
        }
    }
}

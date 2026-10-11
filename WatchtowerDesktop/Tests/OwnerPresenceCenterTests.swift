import AppKit
import GRDB
import Observation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The presence writes a center made, and a switch to fail the next ones.
private final class PresenceWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(session: Int64?, at: Date)] = []
    private var failuresLeft = 0

    var all: [(session: Int64?, at: Date)] { lock.withLock { log } }
    var sessions: [Int64?] { all.map(\.session) }

    func fail(next count: Int) { lock.withLock { failuresLeft = count } }

    func record(_ session: Int64?, _ at: Date) throws {
        try lock.withLock {
            if failuresLeft > 0 {
                failuresLeft -= 1
                throw CancellationError()
            }
            log.append((session, at))
        }
    }
}

/// Time a test moves by hand: the clock and the timers fired by it.
@MainActor
private final class ManualTime {
    private struct Timer {
        let id: Int
        let due: Date
        let fire: @MainActor () -> Void
    }

    private(set) var now: Date
    private var timers: [Timer] = []
    private var nextID = 0

    init(_ now: Date) { self.now = now }

    var pendingTimers: Int { timers.count }

    func schedule(_ seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        timers.append(Timer(id: id, due: now.addingTimeInterval(seconds), fire: fire))
        return { [weak self] in self?.timers.removeAll { $0.id == id } }
    }

    /// Moves the clock, firing every timer due on the way in order.
    func advance(by seconds: TimeInterval) {
        let end = now.addingTimeInterval(seconds)
        while let next = timers.filter({ $0.due <= end }).min(by: { $0.due < $1.due }) {
            timers.removeAll { $0.id == next.id }
            now = next.due
            next.fire()
        }
        now = end
    }
}

/// What the screen shows, observable like the app state the production
/// provider reads.
@MainActor
@Observable
private final class FakeScreen {
    var shown = OwnerPresenceCenter.Screen.other
}

@MainActor
final class OwnerPresenceCenterTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private var time: ManualTime!
    private var writes: PresenceWrites!
    private var notifications: NotificationCenter!
    private var screen: FakeScreen!
    private var center: OwnerPresenceCenter!
    private var changes = 0

    override func setUp() async throws {
        time = ManualTime(start)
        writes = PresenceWrites()
        notifications = NotificationCenter()
        screen = FakeScreen()
        changes = 0
    }

    override func tearDown() async throws {
        center?.stop()
        center = nil
    }

    private func makeCenter(appActive: Bool = true, screenLocked: Bool = false) -> OwnerPresenceCenter {
        let writes: PresenceWrites = writes
        let time: ManualTime = time
        let center = OwnerPresenceCenter(
            writer: { try writes.record($0, $1) },
            clock: { time.now },
            schedule: { time.schedule($0, $1) },
            sources: .init(app: notifications, workspace: notifications, distributed: notifications)
        )
        let screen: FakeScreen = screen
        center.screen = { screen.shown }
        center.isAppActive = { appActive }
        center.isScreenLocked = { screenLocked }
        center.onChange = { [weak self] in self?.changes += 1 }
        self.center = center
        return center
    }

    private func show(_ session: Int64, drawer: Bool = false) {
        screen.shown = .init(keyWindowShows: drawer ? .workbenchSessionWithAskDrawer : .workbenchSession, selectedSession: session)
    }

    private func post(_ name: Notification.Name) {
        notifications.post(name: name, object: nil)
    }

    /// The app is active with session 7's pane in the key window.
    private func startInSession7() async -> OwnerPresenceCenter {
        show(7)
        let center = makeCenter()
        center.start()
        await center.flushWrites()
        return center
    }

    // MARK: - Settling

    func testSettlesAfterTheFirstComputation() async {
        let center = makeCenter(appActive: false)
        XCTAssertFalse(center.hasSettled, "nothing is known before start")
        XCTAssertEqual(changes, 0)

        center.start()
        await center.flushWrites()

        XCTAssertTrue(center.hasSettled)
        XCTAssertNil(center.presentSessionID)
        XCTAssertEqual(changes, 1, "the first computation is a change for the subscriber")
        XCTAssertEqual(writes.sessions, [nil], "the first result is written, clearing a row a crashed run left")
    }

    func testALockedScreenAtLaunchIsAbsent() async {
        show(7)
        let center = makeCenter(screenLocked: true)
        center.start()
        await center.flushWrites()

        XCTAssertNil(center.presentSessionID)
        XCTAssertEqual(writes.sessions, [nil])

        post(OwnerPresenceCenter.screenUnlockedNotification)
        await center.flushWrites()
        XCTAssertEqual(center.presentSessionID, 7)
    }

    func testStartAfterStopWritesAgainAndHeartbeats() async {
        let center = await startInSession7()
        center.stop()
        time.advance(by: 10)

        center.start()
        await center.flushWrites()
        XCTAssertEqual(writes.sessions, [7, 7], "a start writes again")

        time.advance(by: 30)
        await center.flushWrites()
        XCTAssertEqual(writes.sessions, [7, 7, 7])
        XCTAssertEqual(writes.all.last?.at, start.addingTimeInterval(40), "30 s after the restart")
    }

    /// A session not entered since the center started is away from that
    /// start: a later question escalates at once (E10b), an earlier one —
    /// a center re-initialised under a running session — waits the grace.
    func testANeverEnteredSessionIsAwaySinceTheStart() async {
        time.advance(by: 4)
        let center = await startInSession7()
        time.advance(by: 10)

        XCTAssertNil(center.awaySince(sessionID: 7), "present")
        XCTAssertEqual(center.awaySince(sessionID: 8), start.addingTimeInterval(4))
    }

    // MARK: - Entering and the heartbeat

    func testEnteringWritesAtOnce() async {
        let center = makeCenter()
        center.start()
        await center.flushWrites()
        XCTAssertEqual(writes.sessions, [nil])

        show(7)
        center.refresh()
        await center.flushWrites()

        XCTAssertEqual(center.presentSessionID, 7)
        XCTAssertEqual(writes.sessions, [nil, 7])
        XCTAssertEqual(writes.all.last?.at, start, "no debounce on gaining presence")
    }

    func testAScreenChangeIsTracked() async {
        let center = makeCenter()
        center.start()

        show(9)
        await yieldUntil { center.presentSessionID == 9 }
        XCTAssertEqual(center.presentSessionID, 9)
        // A notification-driven evaluation in between keeps the tracker.
        post(NSWindow.didBecomeKeyNotification)
        screen.shown = .other
        // A loss waits for the debounce; the tracking re-armed and saw it.
        await yieldUntil { self.time.pendingTimers == 2 }
        XCTAssertEqual(time.pendingTimers, 2, "the heartbeat and the debounce")
        XCTAssertEqual(center.presentSessionID, 9)
    }

    func testHeartbeatEveryThirtySeconds() async {
        let center = await startInSession7()
        XCTAssertEqual(writes.sessions, [7])

        time.advance(by: 29)
        await center.flushWrites()
        XCTAssertEqual(writes.sessions, [7], "no heartbeat before 30 s")

        time.advance(by: 1)
        await center.flushWrites()
        time.advance(by: 30)
        await center.flushWrites()

        XCTAssertEqual(writes.sessions, [7, 7, 7])
        XCTAssertEqual(writes.all.map(\.at), [start, start.addingTimeInterval(30), start.addingTimeInterval(60)])
    }

    func testAFailedEnterIsRecoveredByTheHeartbeat() async {
        writes.fail(next: 1)
        let center = await startInSession7()
        XCTAssertEqual(writes.sessions, [], "the enter failed")

        time.advance(by: 30)
        await center.flushWrites()

        XCTAssertEqual(writes.sessions, [7], "the heartbeat names the session")
    }

    func testAFailedLeaveIsRetriedUntilItLands() async {
        let center = await startInSession7()
        writes.fail(next: 2)

        screen.shown = .other
        center.refresh()
        time.advance(by: 2)
        await center.flushWrites()
        XCTAssertEqual(writes.sessions, [7], "the leave failed")

        time.advance(by: 30)
        await center.flushWrites()
        XCTAssertEqual(writes.sessions, [7], "the first retry failed too")

        time.advance(by: 30)
        await center.flushWrites()
        XCTAssertEqual(writes.sessions, [7, nil])

        time.advance(by: 120)
        await center.flushWrites()
        XCTAssertEqual(writes.sessions, [7, nil], "no heartbeat out of a session once written")
    }

    // MARK: - Leaving

    func testAFlickerUnderTwoSecondsIsNotLeaving() async {
        let center = await startInSession7()
        changes = 0

        post(NSApplication.didResignActiveNotification)
        time.advance(by: 1)
        post(NSApplication.didBecomeActiveNotification)
        time.advance(by: 5)
        await center.flushWrites()

        XCTAssertEqual(center.presentSessionID, 7)
        XCTAssertNil(center.awaySince(sessionID: 7))
        XCTAssertEqual(writes.sessions, [7], "no presence write")
        XCTAssertEqual(changes, 0)
    }

    func testALossThatLastsIsWrittenAfterTwoSeconds() async {
        let center = await startInSession7()

        post(NSApplication.didResignActiveNotification)
        time.advance(by: 1.9)
        XCTAssertEqual(center.presentSessionID, 7, "still present inside the debounce")
        time.advance(by: 0.1)
        await center.flushWrites()

        XCTAssertNil(center.presentSessionID)
        XCTAssertEqual(writes.sessions, [7, nil])
        XCTAssertEqual(writes.all.last?.at, start.addingTimeInterval(2))
        XCTAssertEqual(center.awaySince(sessionID: 7), start.addingTimeInterval(2), "away since the loss was written")
    }

    func testAnotherSessionOnScreenIsEnteredAtOnce() async {
        let center = await startInSession7()
        time.advance(by: 5)

        show(8, drawer: true)
        center.refresh()
        await center.flushWrites()

        XCTAssertEqual(center.presentSessionID, 8, "the ask drawer beside it still counts")
        XCTAssertEqual(writes.sessions, [7, 8])
        XCTAssertEqual(center.awaySince(sessionID: 7), start.addingTimeInterval(5))
    }

    func testScreenLockClears() async {
        let center = await startInSession7()
        time.advance(by: 3)

        post(OwnerPresenceCenter.screenLockedNotification)
        await center.flushWrites()

        XCTAssertNil(center.presentSessionID, "no debounce on a lock")
        XCTAssertEqual(writes.sessions, [7, nil])
        XCTAssertEqual(center.awaySince(sessionID: 7), start.addingTimeInterval(3))

        post(OwnerPresenceCenter.screenUnlockedNotification)
        await center.flushWrites()
        XCTAssertEqual(center.presentSessionID, 7, "back on unlock")
        XCTAssertEqual(writes.sessions, [7, nil, 7])
    }

    func testALockInsideTheDebounceIsAwayFromTheLock() async {
        let center = await startInSession7()

        post(NSApplication.didResignActiveNotification)
        time.advance(by: 1)
        post(OwnerPresenceCenter.screenLockedNotification)
        await center.flushWrites()

        XCTAssertEqual(writes.sessions, [7, nil])
        XCTAssertEqual(center.awaySince(sessionID: 7), start.addingTimeInterval(1), "away from the written clear")
        time.advance(by: 5)
        await center.flushWrites()
        XCTAssertEqual(writes.sessions, [7, nil], "the cancelled debounce writes nothing more")
    }

    func testASwitchInsideTheDebounceIsAwayFromTheSwitch() async {
        let center = await startInSession7()

        screen.shown = .other
        center.refresh()
        time.advance(by: 1.5)
        show(8)
        center.refresh()
        await center.flushWrites()

        XCTAssertEqual(center.presentSessionID, 8)
        XCTAssertEqual(writes.sessions, [7, 8])
        XCTAssertEqual(center.awaySince(sessionID: 7), start.addingTimeInterval(1.5))
    }

    func testDisplaySleepClears() async {
        let center = await startInSession7()

        post(NSWorkspace.screensDidSleepNotification)
        await center.flushWrites()
        XCTAssertNil(center.presentSessionID)
        XCTAssertEqual(writes.sessions, [7, nil])

        post(NSWorkspace.screensDidWakeNotification)
        await center.flushWrites()
        XCTAssertEqual(center.presentSessionID, 7)
    }

    func testQuitClearsPresence() async {
        let center = await startInSession7()

        center.clearForQuit()

        XCTAssertEqual(writes.sessions, [7, nil], "cleared before returning")
        XCTAssertNil(center.presentSessionID)
        XCTAssertEqual(time.pendingTimers, 0, "no heartbeat left")
        post(NSApplication.didBecomeActiveNotification)
        time.advance(by: 60)
        await center.flushWrites()
        XCTAssertEqual(writes.sessions, [7, nil], "nothing written after quit")
    }

    func testQuitClearsAfterAnEnterNotYetWritten() {
        show(7)
        let center = makeCenter()
        center.start()

        center.clearForQuit()

        XCTAssertEqual(writes.sessions, [7, nil], "the queued enter, then the clear")
    }

    func testStopLeavesNoTimerAndNoObserver() async {
        let center = await startInSession7()

        center.stop()
        post(OwnerPresenceCenter.screenLockedNotification)
        time.advance(by: 60)
        await center.flushWrites()

        XCTAssertEqual(writes.sessions, [7])
        XCTAssertEqual(time.pendingTimers, 0)
    }

    // MARK: - Helpers

    /// Lets the main actor run the observation hop's task; bounded, with
    /// no wall clock.
    private func yieldUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1_000 where !condition() {
            await Task.yield()
        }
    }
}

/// What the workbench page reports to the presence center, and the
/// center's wiring on `AppState`.
@MainActor
final class WorkbenchOwnerPresenceScreenTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var folder: URL!
    private var appState: AppState!
    private var projectID: Int64 = 0
    /// Each started session's fake process, by the order started.
    private var processes: [FakeTerminalSession] = []

    override func setUp() async throws {
        processes = []
        (pool, path) = try TestDatabase.createPool()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt-presence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folderPath = folder.path
        projectID = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: folderPath) }
        appState = AppState.isolated()
        // pid 0: nothing here ever signals a real process group.
        appState.terminalCenter.claudeBinary = { nil }
        appState.terminalCenter.makeProcess = { [weak self] in
            let process = FakeTerminalSession(pid: 0)
            self?.processes.append(process)
            return process
        }
        appState.terminalCenter.transcriptExists = { _ in true }
        UserDefaults.standard.removeObject(forKey: WorkspaceLayout.key(workbenchID: projectID))
        appState.initWorkbenches(
            dbPool: pool, cliRunner: nil, notifier: RecordingWorkbenchNotifier(),
            sessionNotifier: RecordingSessionNotifier()
        )
    }

    override func tearDown() async throws {
        appState.workbenchNotificationCenter?.stop()
        appState.sessionAgentStateCenter?.stop()
        appState.ownerPresenceCenter?.stop()
        // The settle write lands before the database file goes.
        await appState.ownerPresenceCenter?.flushWrites()
        UserDefaults.standard.removeObject(forKey: WorkspaceLayout.key(workbenchID: projectID))
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

    private func page() async throws -> WorkbenchesViewModel {
        let vm = try XCTUnwrap(appState.workbenchesViewModel)
        await vm.reload()
        vm.selectedWorkbenchID = projectID
        await vm.loadSessions(projectID: projectID)
        return vm
    }

    func testTheCenterIsStartedWithTheWorkbenches() async throws {
        let center = try XCTUnwrap(appState.ownerPresenceCenter)
        XCTAssertTrue(center.hasSettled)
        XCTAssertNil(center.presentSessionID, "no key main window in a test run")
    }

    func testTheSessionOnScreenIsReported() async throws {
        let session = try await insertSession("a")
        let vm = try await page()

        await vm.showSession(id: session.id)

        XCTAssertEqual(vm.ownerPresenceScreen(), .init(keyWindowShows: .workbenchSession, selectedSession: session.id))
    }

    /// A | B split, A shown last.
    private func split() async throws -> (vm: WorkbenchesViewModel, a: TerminalSession, b: TerminalSession) {
        let a = try await insertSession("a")
        let b = try await insertSession("b")
        let vm = try await page()
        await vm.showSession(id: b.id)
        await vm.showSession(id: a.id)
        var layout = vm.layout(projectID: projectID)
        layout.split(with: .session(b.id))
        vm.setLayout(layout, projectID: projectID)
        return (vm, a, b)
    }

    func testTheSessionFocusedLastOfTwoOnScreenIsReported() async throws {
        let (vm, a, _) = try await split()
        XCTAssertEqual(appState.terminalCenter.focusOrder.last, a.id)

        XCTAssertEqual(vm.ownerPresenceScreen().selectedSession, a.id)
    }

    func testAClickIntoTheOtherTerminalOfASplitSelectsIt() async throws {
        let (vm, _, b) = try await split()
        // The processes start in click order: b, then a.
        let processB = try XCTUnwrap(processes.first)

        processB.onOwnerFocus?()

        XCTAssertEqual(appState.terminalCenter.focusOrder.last, b.id)
        XCTAssertEqual(vm.ownerPresenceScreen().selectedSession, b.id)
    }

    func testASessionBesideTheBoardIsReported() async throws {
        let session = try await insertSession("a")
        let vm = try await page()
        await vm.showSession(id: session.id)
        var layout = WorkspaceLayout.default
        layout.split(with: .session(session.id))
        vm.setLayout(layout, projectID: projectID)

        XCTAssertEqual(vm.ownerPresenceScreen().selectedSession, session.id)
    }

    func testAnExpandedBoardHidingTheSessionIsOther() async throws {
        let session = try await insertSession("a")
        let vm = try await page()
        await vm.showSession(id: session.id)
        var layout = WorkspaceLayout.default
        layout.split(with: .session(session.id))
        layout.toggleExpand(.board)
        vm.setLayout(layout, projectID: projectID)

        XCTAssertEqual(vm.ownerPresenceScreen(), .other)
    }

    func testAStandaloneTerminalIsOther() async throws {
        let session = try await insertSession("a")
        let vm = try await page()
        await vm.showSession(id: session.id)

        vm.selectedStandaloneID = session.id

        XCTAssertEqual(vm.ownerPresenceScreen(), .other)
    }

    func testTheDrawerOfThatSessionIsReported() async throws {
        let session = try await insertSession("a")
        let vm = try await page()
        await vm.showSession(id: session.id)
        let projectID = projectID
        let askID = try await pool.write {
            try TestDatabase.insertOwnerAsk(
                $0, projectID: projectID, sessionID: session.id,
                payload: #"{"questions":[{"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}]}"#
            )
        }
        await vm.asks.load(projectID: projectID)

        vm.asks.openDrawer(askID: askID, projectID: projectID)

        XCTAssertEqual(vm.ownerPresenceScreen(), .init(keyWindowShows: .workbenchSessionWithAskDrawer, selectedSession: session.id))
    }

    func testOnlyTheWorkbenchTabInTheKeyMainWindowCounts() async throws {
        let session = try await insertSession("a")
        let vm = try await page()
        await vm.showSession(id: session.id)
        let center = try XCTUnwrap(appState.ownerPresenceCenter)
        var key = true
        appState.mainWindowIsKey = { key }

        appState.selectedDestination = .workbench
        XCTAssertEqual(center.screen().selectedSession, session.id)

        key = false
        XCTAssertEqual(center.screen(), .other, "the main window is not key")

        key = true
        appState.selectedDestination = .inbox
        XCTAssertEqual(center.screen(), .other, "another tab")
    }

    func testNoSessionPaneIsOther() async throws {
        let vm = try await page()
        vm.setLayout(.default, projectID: projectID)

        XCTAssertEqual(vm.ownerPresenceScreen(), .other, "the board alone")
    }
}

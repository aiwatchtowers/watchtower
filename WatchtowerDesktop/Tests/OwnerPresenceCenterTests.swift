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

    private func makeCenter(appActive: Bool = true) -> OwnerPresenceCenter {
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

    func testANeverEnteredSessionIsAwaySinceBeforeAnyQuestion() async {
        let center = await startInSession7()

        XCTAssertNil(center.awaySince(sessionID: 7), "present")
        XCTAssertEqual(center.awaySince(sessionID: 8), .distantPast)
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

    func testAScreenChangeIsTracked() async throws {
        let center = makeCenter()
        center.start()

        show(9)
        try await waitUntil { center.presentSessionID == 9 }
        screen.shown = .other
        // A loss waits for the debounce; the tracking re-armed and saw it.
        try await waitUntil { self.time.pendingTimers == 2 }
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
        XCTAssertEqual(center.awaySince(sessionID: 7), start, "away since the loss began")
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

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(5))
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

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt-presence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folderPath = folder.path
        projectID = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: folderPath) }
        appState = AppState.isolated()
        // pid 0: nothing here ever signals a real process group.
        appState.terminalCenter.makeProcess = { FakeTerminalSession(pid: 0) }
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

    func testTheActiveSessionOfTwoOnScreenIsReported() async throws {
        let first = try await insertSession("a")
        let second = try await insertSession("b")
        let vm = try await page()
        await vm.showSession(id: second.id)
        await vm.showSession(id: first.id)
        var layout = vm.layout(projectID: projectID)
        layout.split(with: .session(second.id))
        vm.setLayout(layout, projectID: projectID)
        XCTAssertEqual(appState.terminalCenter.focusOrder.last, first.id)

        XCTAssertEqual(vm.ownerPresenceScreen().selectedSession, first.id)
    }

    func testNoSessionPaneIsOther() async throws {
        let vm = try await page()
        vm.setLayout(.default, projectID: projectID)

        XCTAssertEqual(vm.ownerPresenceScreen(), .other, "the board alone")
    }
}

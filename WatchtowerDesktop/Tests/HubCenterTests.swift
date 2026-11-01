import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The center's waits, parked until the test releases them by duration.
private final class HubManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: [(Duration, CheckedContinuation<Void, Never>)] = []
    private var all: [Duration] = []

    var waits: [Duration] { lock.withLock { all } }

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                all.append(duration)
                parked.append((duration, continuation))
            }
        }
    }

    func parkedCount(_ duration: Duration) -> Int {
        lock.withLock { parked.filter { $0.0 == duration }.count }
    }

    /// Ends every wait of `duration` parked now.
    func release(_ duration: Duration) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            let due = parked.filter { $0.0 == duration }.map(\.1)
            parked.removeAll { $0.0 == duration }
            return due
        }
        due.forEach { $0.resume() }
    }

    func releaseAll() {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            let due = parked.map(\.1)
            parked = []
            return due
        }
        due.forEach { $0.resume() }
    }
}

/// The control socket as the center sees it: answers scripted per op, every
/// request recorded, watch streams handed to the test.
private final class FakeHubClient: HubControlClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [HubControlRequest] = []
    private var streams: [AsyncThrowingStream<HubEvent, Error>.Continuation] = []
    private var watchCalls = 0
    private var isReachable = true
    var reachable: Bool {
        get { lock.withLock { isReachable } }
        set { lock.withLock { isReachable = newValue } }
    }
    private var answer = HubControlAnswer(op: HubControlRequest.desktopHeartbeat, ok: true)
    var heartbeatAnswer: HubControlAnswer {
        get { lock.withLock { answer } }
        set { lock.withLock { answer = newValue } }
    }
    /// While set, a view send waits in `held` until `releaseViews()`.
    private var hold = false
    private var held: [CheckedContinuation<Void, Never>] = []
    var holdViews: Bool {
        get { lock.withLock { hold } }
        set { lock.withLock { hold = newValue } }
    }
    var heldViews: Int { lock.withLock { held.count } }

    func releaseViews() {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            hold = false
            defer { held = [] }
            return held
        }
        due.forEach { $0.resume() }
    }

    var sent: [HubControlRequest] { lock.withLock { requests } }
    var views: [HubControlRequest] { sent.filter { $0.op == HubControlRequest.desktopView } }
    var heartbeats: Int { sent.filter { $0.op == HubControlRequest.desktopHeartbeat }.count }
    var watches: Int { lock.withLock { watchCalls } }

    func send(_ request: HubControlRequest) async throws -> HubControlAnswer {
        guard reachable else { throw HubControlError.noHub }
        lock.withLock { requests.append(request) }
        if request.op == HubControlRequest.desktopHeartbeat { return heartbeatAnswer }
        if holdViews {
            await withCheckedContinuation { continuation in
                let parked = lock.withLock { () -> Bool in
                    guard hold else { return false }
                    held.append(continuation)
                    return true
                }
                if !parked { continuation.resume() }
            }
        }
        return HubControlAnswer(op: request.op, ok: true)
    }

    func watch() -> AsyncThrowingStream<HubEvent, Error> {
        lock.withLock { watchCalls += 1 }
        guard reachable else {
            return AsyncThrowingStream { $0.finish(throwing: HubControlError.noHub) }
        }
        return AsyncThrowingStream { continuation in lock.withLock { streams.append(continuation) } }
    }

    func emit(_ event: HubEvent) {
        lock.withLock { streams.last }?.yield(event)
    }

    func endStream() {
        lock.withLock { streams.last }?.finish(throwing: HubControlError.closed)
    }
}

@MainActor
final class HubCenterTests: XCTestCase {
    private var sleeper: HubManualSleeper!
    private var client: FakeHubClient!
    private var centers: [HubCenter] = []

    override func setUp() {
        super.setUp()
        sleeper = HubManualSleeper()
        client = FakeHubClient()
    }

    override func tearDown() {
        centers.forEach { $0.stop() }
        sleeper.releaseAll()
        super.tearDown()
    }

    private func makeCenter(
        cli: (any CLIRunnerProtocol)? = nil, heartbeat: Duration = HubCenter.heartbeatInterval
    ) -> HubCenter {
        let sleeper: HubManualSleeper = self.sleeper
        let center = HubCenter(client: client, cli: cli, heartbeatInterval: heartbeat) { await sleeper.sleep($0) }
        centers.append(center)
        return center
    }

    func testHeartbeatEvery30Seconds() async {
        let center = makeCenter()
        center.start()
        await waitUntil("the first beat") { client.heartbeats == 1 && sleeper.parkedCount(HubCenter.heartbeatInterval) == 1 }
        XCTAssertEqual(client.heartbeats, 1, "no second beat before 30 s")
        sleeper.release(HubCenter.heartbeatInterval)
        await waitUntil("the second beat") { client.heartbeats == 2 && sleeper.parkedCount(HubCenter.heartbeatInterval) == 1 }
        sleeper.release(HubCenter.heartbeatInterval)
        await waitUntil("the third beat") { client.heartbeats == 3 }
        XCTAssertEqual(sleeper.waits.filter { $0 == HubCenter.heartbeatInterval }.count, 3)
    }

    func testWatchReconnectsWithBackoff() async {
        client.reachable = false
        // A heartbeat wait apart from the backoff's 30 s.
        let beat = Duration.seconds(999)
        let center = makeCenter(heartbeat: beat)
        center.start()
        let expected: [Duration] = [1, 2, 4, 8, 16, 30, 30].map { .seconds($0) }
        for wait in expected {
            await waitUntil("a reconnect after \(wait)") { sleeper.parkedCount(wait) == 1 }
            sleeper.release(wait)
        }
        await waitUntil("the next wait") { sleeper.parkedCount(.seconds(30)) == 1 }
        XCTAssertEqual(Array(sleeper.waits.filter { $0 != beat }.prefix(expected.count)), expected)
        XCTAssertEqual(client.watches, 8)

        // A snapshot resets the backoff: the next drop waits 1 s again.
        client.reachable = true
        sleeper.release(.seconds(30))
        await waitUntil("the stream is open") { client.watches == 9 }
        client.emit(.snapshot(HubCenter.Status(state: "running")))
        await waitUntil("the snapshot applied") { center.status == HubCenter.Status(state: "running") }
        client.endStream()
        await waitUntil("a reconnect after 1 s") { sleeper.parkedCount(HubCenter.firstBackoff) == 1 }
    }

    func testStatusFromTheWatchAnswer() async {
        let center = makeCenter()
        center.start()
        await waitUntil("the stream is open") { client.watches == 1 }
        client.emit(.snapshot(HubCenter.Status(state: "off", reason: "disabled")))
        await waitUntil("the snapshot") { center.status == HubCenter.Status(state: "off", reason: "disabled") }
        client.emit(.status(HubCenter.Status(state: "running")))
        await waitUntil("the status event") { center.status == HubCenter.Status(state: "running") }
        client.emit(.recordingQueued(uploadID: "u-1"))
        client.emit(.status(HubCenter.Status(state: "paused", reason: "locked")))
        await waitUntil("only status events change it") { center.status == HubCenter.Status(state: "paused", reason: "locked") }
    }

    /// The phone recording queue's two inputs: each snapshot (a rescan) and
    /// each `recording_queued` with its upload id.
    func testRecordingEventsReachTheQueue() async {
        let center = makeCenter()
        var connected = 0
        var queued: [String] = []
        center.onWatchConnected = { connected += 1 }
        center.onRecordingQueued = { queued.append($0) }
        center.start()
        await waitUntil("the stream is open") { client.watches == 1 }
        client.emit(.snapshot(HubCenter.Status(state: "running")))
        client.emit(.recordingQueued(uploadID: "u-1"))
        client.emit(.recordingQueued(uploadID: ""))
        client.emit(.recordingQueued(uploadID: "u-2"))
        await waitUntil("the events") { queued.count == 2 }
        XCTAssertEqual(connected, 1)
        XCTAssertEqual(queued, ["u-1", "u-2"], "an event with no id is dropped")
    }

    func testNoHubFallsBackToCLIStatus() async throws {
        client.reachable = false
        let cli = FakeCLIRunner(stdout: Data(#"{"state":"off","reason":"desktop_host","host":"desktop","recordings":"off"}"#.utf8))
        let center = makeCenter(cli: cli)
        center.publishView(hidden: [3], displayOver: [:])
        center.start()
        await waitUntil("the CLI status") { center.status?.reason == "desktop_host" }
        XCTAssertEqual(center.status, HubCenter.Status(state: "off", reason: "desktop_host", host: "desktop", recordings: "off"))
        // More failed beats and reconnects: no second CLI read in the streak, nothing sent.
        await waitUntil("both loops wait") {
            sleeper.parkedCount(HubCenter.heartbeatInterval) == 1 && sleeper.parkedCount(HubCenter.firstBackoff) == 1
        }
        sleeper.release(HubCenter.heartbeatInterval)
        sleeper.release(HubCenter.firstBackoff)
        await waitUntil("a second beat and reconnect") {
            sleeper.parkedCount(HubCenter.heartbeatInterval) == 1 && sleeper.parkedCount(.seconds(2)) == 1
        }
        XCTAssertEqual(cli.invocations, [HubCenter.statusArgs])
        XCTAssertTrue(client.sent.isEmpty, "no hub: no heartbeat answered, no view sent")
    }

    func testNoHubAndNoCLIReadsAsNotRunning() async {
        client.reachable = false
        let center = makeCenter()
        center.start()
        await waitUntil("not running") { center.status == HubCenter.notRunning }
    }

    func testViewSentAtStartAfterTheFirstHeartbeat() async {
        let center = makeCenter()
        center.publishView(hidden: [7], displayOver: [:])
        center.start()
        await waitUntil("the view") { client.views.count == 1 }
        XCTAssertEqual(client.sent.first?.op, HubControlRequest.desktopHeartbeat, "the beat goes first")
        XCTAssertEqual(client.views.first?.hidden, [7])
        // An unchanged view is not sent again on the next beat.
        sleeper.release(HubCenter.heartbeatInterval)
        await waitUntil("the second beat") { client.heartbeats == 2 && sleeper.parkedCount(HubCenter.heartbeatInterval) == 1 }
        XCTAssertEqual(client.views.count, 1)
    }

    func testViewResentOnViewNeeded() async {
        let center = makeCenter()
        center.publishView(hidden: [7], displayOver: [:])
        center.start()
        await waitUntil("the first view") { client.views.count == 1 && sleeper.parkedCount(HubCenter.heartbeatInterval) == 1 }
        // The hub restarted: it holds no view.
        client.heartbeatAnswer = HubControlAnswer(op: HubControlRequest.desktopHeartbeat, ok: true, viewNeeded: true)
        sleeper.release(HubCenter.heartbeatInterval)
        await waitUntil("the view again") { client.views.count == 2 }
        XCTAssertEqual(client.views.last, client.views.first, "the whole, unchanged view")
    }

    func testViewChangesAreCoalesced() async {
        let center = makeCenter()
        center.start()
        await waitUntil("the start view") { client.views.count == 1 }
        center.publishView(hidden: [1], displayOver: [:])
        center.publishView(hidden: [1, 2], displayOver: [:])
        await waitUntil("one coalesced wait") { sleeper.parkedCount(HubCenter.viewCoalesce) == 1 }
        XCTAssertEqual(client.views.count, 1, "nothing before the 250 ms")
        sleeper.release(HubCenter.viewCoalesce)
        await waitUntil("one send") { client.views.count == 2 }
        XCTAssertEqual(client.views.last?.hidden, [1, 2])
    }

    /// PROJ-17: a pending delete reaches the hub with that id; Undo sends
    /// the view without it.
    func testUndoBatchReachesTheHub() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt hub \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HubCenterTests-\(UUID().uuidString)"))
        let terminals = TerminalCenter { FakeTerminalSession(pid: 0) }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: terminals)
        vm.titleService = { _ in .init(title: "", written: false) }
        let sleeper: HubManualSleeper = self.sleeper
        vm.deleteSleep = { await sleeper.sleep($0) }
        let projectID = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: folder.path) }
        let row = try await pool.write {
            try TerminalSessionQueries.create($0, .init(
                projectID: projectID, kind: .claude, title: "Session A", targetID: nil, folderPath: folder.path,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
        }
        let center = makeCenter()
        center.follow(workbenches: vm, agentStates: nil)
        center.start()
        await waitUntil("the start view") { client.views.count == 1 }
        XCTAssertEqual(client.views.last?.hidden, [])
        await vm.reload()

        await vm.delete(row)
        await waitUntil("the coalesce wait") { sleeper.parkedCount(HubCenter.viewCoalesce) == 1 }
        sleeper.release(HubCenter.viewCoalesce)
        await waitUntil("the pending delete") { client.views.count == 2 }
        XCTAssertEqual(client.views.last?.hidden, [row.id])

        await vm.undoPendingDeletes()
        await waitUntil("the coalesce wait") { sleeper.parkedCount(HubCenter.viewCoalesce) == 1 }
        sleeper.release(HubCenter.viewCoalesce)
        await waitUntil("the Undo") { client.views.count == 3 }
        XCTAssertEqual(client.views.last?.hidden, [])
    }

    /// F10: `initWorkbenches` builds the center through the factory and
    /// follows the view; a rebuild stops the previous one; the quit stops it.
    func testAppStateReplacesAndStopsTheHubCenter() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let appState = AppState()
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.terminalCenter.shell = { "/bin/zsh" }
        var built: [HubCenter] = []
        appState.makeHubCenter = { [weak self] cli in
            guard let center = self?.makeCenter(cli: cli) else { return nil }
            built.append(center)
            return center
        }
        func initWorkbenches() {
            appState.initWorkbenches(
                dbPool: pool, cliRunner: FakeCLIRunner(), notifier: RecordingWorkbenchNotifier(),
                sessionNotifier: RecordingSessionNotifier()
            )
        }
        defer {
            appState.sessionAgentStateCenter?.stop()
            appState.workbenchNotificationCenter?.stop()
        }
        initWorkbenches()
        let first = try XCTUnwrap(appState.hubCenter)
        XCTAssertTrue(first.isRunning)
        XCTAssertNotNil(appState.workbenchesViewModel?.onHiddenSessionsChanged, "follows the Undo batch")
        XCTAssertNotNil(appState.sessionAgentStateCenter?.onDisplayOverChange, "follows the shown-over counts")

        initWorkbenches()
        XCTAssertFalse(first.isRunning, "a rebuild stops the previous center")
        let second = try XCTUnwrap(appState.hubCenter)
        XCTAssertTrue(second !== first && second.isRunning)
        XCTAssertEqual(built.count, 2)

        appState.stopHubCenterForQuit()
        XCTAssertFalse(second.isRunning)
    }

    /// #411: a count shown over goes as `{id, run, reported_at}` with the
    /// run and the report stamp it was judged for.
    func testDisplayOverReachesTheHub() async {
        let run = Date(timeIntervalSince1970: 1_799_999_000.5)
        let center = makeCenter()
        center.publishView(hidden: [], displayOver: [
            5: ShownOverCount(run: run, reportedAt: "2027-01-15T07:43:21.000Z"),
            6: ShownOverCount(run: nil, reportedAt: nil)
        ])
        center.start()
        await waitUntil("the view") { client.views.count == 1 }
        XCTAssertEqual(client.views.first?.displayOver, [
            HubShownOver(id: 5, run: run, reportedAt: "2027-01-15T07:43:21.000Z"),
            HubShownOver(id: 6, run: nil, reportedAt: nil)
        ])
    }

    /// F1: a view changed while no hub answered goes with the first beat
    /// answered again.
    func testViewMadeWhileNoHubAnswersGoesWhenItAnswersAgain() async {
        let center = makeCenter()
        center.start()
        await waitUntil("the start view") { client.views.count == 1 && sleeper.parkedCount(HubCenter.heartbeatInterval) == 1 }
        client.reachable = false
        sleeper.release(HubCenter.heartbeatInterval)
        await waitUntil("a failed beat") { sleeper.parkedCount(HubCenter.heartbeatInterval) == 1 }
        center.publishView(hidden: [4], displayOver: [:])
        await waitUntil("the coalesce wait") { sleeper.parkedCount(HubCenter.viewCoalesce) == 1 }
        sleeper.release(HubCenter.viewCoalesce)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(client.views.count, 1, "nothing sent while no hub answers")

        client.reachable = true
        sleeper.release(HubCenter.heartbeatInterval)
        await waitUntil("the view after the hub answers") { client.views.count == 2 }
        XCTAssertEqual(client.views.last?.hidden, [4])
    }

    /// F2: the heartbeat owns reachability. A watch that ends while beats
    /// answer only reconnects: no CLI fallback over the status, and views
    /// still go.
    func testAWatchEndingWhileHeartbeatsAnswerOnlyReconnects() async {
        let cli = FakeCLIRunner(stdout: Data(#"{"state":"running","hub_id":"hub-acme"}"#.utf8))
        let center = makeCenter(cli: cli)
        center.start()
        await waitUntil("the start view") { client.views.count == 1 }
        await waitUntil("the stream is open") { client.watches == 1 }
        client.emit(.snapshot(HubCenter.Status(state: "running")))
        // One read when the beat first answered, one after the snapshot.
        await waitUntil("the full status") { center.status?.hubID == "hub-acme" && cli.invocations.count == 2 }
        let reads = cli.invocations.count

        client.endStream()
        await waitUntil("a reconnect wait") { sleeper.parkedCount(HubCenter.firstBackoff) == 1 }
        XCTAssertEqual(center.status, HubCenter.Status(state: "running", hubID: "hub-acme"), "the status is kept")
        XCTAssertEqual(cli.invocations.count, reads, "no fallback read for a dropped stream")
        center.publishView(hidden: [8], displayOver: [:])
        await waitUntil("the coalesce wait") { sleeper.parkedCount(HubCenter.viewCoalesce) == 1 }
        sleeper.release(HubCenter.viewCoalesce)
        await waitUntil("the view still goes") { client.views.count == 2 }
        XCTAssertEqual(client.views.last?.hidden, [8])
        sleeper.release(HubCenter.firstBackoff)
        await waitUntil("the watch reconnects") { client.watches == 2 }
    }

    /// F4: a `view_needed` during a send in flight sends the view once more
    /// after it, even unchanged.
    func testViewNeededDuringASendKeepsItsForce() async {
        let center = makeCenter()
        center.start()
        await waitUntil("the start view") { client.views.count == 1 && sleeper.parkedCount(HubCenter.heartbeatInterval) == 1 }
        client.holdViews = true
        center.publishView(hidden: [2], displayOver: [:])
        await waitUntil("the coalesce wait") { sleeper.parkedCount(HubCenter.viewCoalesce) == 1 }
        sleeper.release(HubCenter.viewCoalesce)
        await waitUntil("the change is in flight") { client.heldViews == 1 }

        client.heartbeatAnswer = HubControlAnswer(op: HubControlRequest.desktopHeartbeat, ok: true, viewNeeded: true)
        sleeper.release(HubCenter.heartbeatInterval)
        await waitUntil("the beat answered") { client.heartbeats == 2 }
        client.releaseViews()
        await waitUntil("the view again after the send") { client.views.count == 3 }
        XCTAssertEqual(client.views[2], client.views[1], "the same view, forced")
    }

    /// F5: while the hub answers, the full status comes from the CLI (on
    /// connect and after each watch status), its state and reason the watch's.
    func testFullStatusFromTheCLIWhileTheHubAnswers() async {
        let cli = FakeCLIRunner(stdout: Data("""
            {"state":"off","reason":"desktop_host","hub_id":"hub-acme","transport":"cloudkit","host":"desktop",
             "mode":"live","recordings":"on","adoption":"done"}
            """.utf8))
        let center = makeCenter(cli: cli)
        center.start()
        await waitUntil("the stream is open") { client.watches == 1 }
        client.emit(.snapshot(HubCenter.Status(state: "running")))
        await waitUntil("the full status") { center.status?.state == "running" && cli.invocations.count == 2 }
        XCTAssertEqual(center.status, HubCenter.Status(
            state: "running", hubID: "hub-acme", transport: "cloudkit", host: "desktop", mode: "live",
            recordings: "on", adoption: "done"
        ))
        let reads = cli.invocations.count
        client.emit(.status(HubCenter.Status(state: "paused", reason: "locked")))
        await waitUntil("re-read after a status event") { cli.invocations.count > reads }
        await waitUntil("the state is the watch's") { center.status?.state == "paused" }
        XCTAssertEqual(center.status?.reason, "locked")
        XCTAssertEqual(center.status?.recordings, "on")
    }

    func testStopEndsHeartbeatAndWatch() async {
        let center = makeCenter()
        center.start()
        await waitUntil("the first beat") { client.heartbeats == 1 && sleeper.parkedCount(HubCenter.heartbeatInterval) == 1 }
        center.stop()
        XCTAssertFalse(center.isRunning)
        sleeper.releaseAll()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(client.heartbeats, 1)
    }
}

@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async {
    for _ in 0..<500 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition(), what)
}

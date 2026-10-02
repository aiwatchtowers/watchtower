import XCTest
@testable import WatchtowerCore

@MainActor
final class OnboardingFinishPlanTests: XCTestCase {
    private struct Boom: Error {}

    private final class Daemon: DaemonControl {
        var running: Bool
        var startOK = true
        var restartFails = false
        var calls: [String] = []
        init(running: Bool) { self.running = running }
        func daemonIsRunning() -> Bool { running }
        func startDetached() async -> Bool {
            calls.append("start")
            return startOK
        }
        func restartWaiting() async throws {
            calls.append("restart")
            if restartFails { throw Boom() }
        }
        func stopDaemonNow() async { calls.append("stop") }
    }

    func testStartsAStoppedDaemonAndRestartsARunningOne() async {
        let stopped = Daemon(running: false)
        let started = await OnboardingFinishPlan.bringUpDaemon(stopped)
        XCTAssertEqual(stopped.calls, ["start"])
        XCTAssertTrue(started)

        let running = Daemon(running: true)
        let restarted = await OnboardingFinishPlan.bringUpDaemon(running)
        XCTAssertEqual(running.calls, ["restart"])
        XCTAssertTrue(restarted)
    }

    func testFailuresAreReported() async {
        let stopped = Daemon(running: false)
        stopped.startOK = false
        let started = await OnboardingFinishPlan.bringUpDaemon(stopped)
        XCTAssertFalse(started)

        let running = Daemon(running: true)
        running.restartFails = true
        let restarted = await OnboardingFinishPlan.bringUpDaemon(running)
        XCTAssertFalse(restarted)
    }

    func testLanding() {
        XCTAssertEqual(OnboardingFinishPlan.landing(goals: [.workCommunication], catchUpVisible: true), .catchUp)
        XCTAssertEqual(OnboardingFinishPlan.landing(goals: [.workCommunication, .development], catchUpVisible: false), .workbench,
                       "no Catch-Up tab to land on")
        XCTAssertEqual(OnboardingFinishPlan.landing(goals: [.workCommunication], catchUpVisible: false), .chat)
        XCTAssertEqual(OnboardingFinishPlan.landing(goals: [.development, .meetings], catchUpVisible: true), .workbench)
        XCTAssertEqual(OnboardingFinishPlan.landing(goals: [.tasksAndJira, .meetings], catchUpVisible: true), .chat)
        XCTAssertEqual(OnboardingFinishPlan.landing(goals: [], catchUpVisible: false), .chat)
    }

    private func progress(active: Bool, updated: Date) throws -> SyncProgress {
        let stamp = ISO8601DateFormatter().string(from: updated)
        let json = #"{"active":\#(active),"phase":"Messages","detail":"34/105 channels","messages_fetched":120,"updated_at":"\#(stamp)"}"#
        return try JSONDecoder().decode(SyncProgress.self, from: Data(json.utf8))
    }

    private func text(
        _ progress: SyncProgress?,
        lastSync: Date? = nil,
        days: Int = 7,
        connected: ConnectedSources = ConnectedSources(slack: true),
        now: Date
    ) -> (title: String, detail: String)? {
        OnboardingFinishPlan.firstSyncText(
            progress: progress, lastSyncTime: lastSync, historyDays: days, connected: connected, now: now
        )
    }

    func testFirstSyncTextWhileTheFirstSyncRuns() throws {
        let now = Date()
        let syncing = try progress(active: true, updated: now)
        XCTAssertEqual(text(syncing, now: now)?.title, "Syncing Slack for the last 7 days — usually 3–5 min")
        XCTAssertEqual(text(syncing, now: now)?.detail, "Messages · 34/105 channels")
        XCTAssertEqual(text(syncing, days: 1, now: now)?.title, "Syncing Slack for the last day — usually 3–5 min")
    }

    /// Worded from what is connected.
    func testFirstSyncTextNamesTheSources() throws {
        let now = Date()
        let syncing = try progress(active: true, updated: now)
        XCTAssertEqual(text(syncing, connected: ConnectedSources(slack: true, mail: true), now: now)?.title,
                       "Syncing Slack and mail for the last 7 days — usually 3–5 min")
        XCTAssertEqual(text(syncing, connected: ConnectedSources(mail: true), now: now)?.title, "Syncing mail — usually 3–5 min")
        XCTAssertEqual(text(syncing, connected: ConnectedSources(), now: now)?.title, "Syncing your sources — usually 3–5 min")
    }

    /// Only before the first finished sync: a routine sync later on keeps
    /// the ordinary empty state.
    func testNoFirstSyncTextOnceASyncFinished() throws {
        let now = Date()
        let syncing = try progress(active: true, updated: now)
        XCTAssertNil(text(syncing, lastSync: now.addingTimeInterval(-3600), now: now))
    }

    func testNoFirstSyncTextWhenIdleOrStale() throws {
        let now = Date()
        XCTAssertNil(text(nil, now: now))
        XCTAssertNil(text(try progress(active: false, updated: now), now: now))
        XCTAssertNil(text(try progress(active: true, updated: now.addingTimeInterval(-SyncProgress.staleAfter - 60)), now: now))
    }

    func testClearingStampsKeepsEverythingElse() throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("stamps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for name in ["last_people.txt", "briefing_attempts.txt", "last_sync.json", "watchtower.db"] {
            FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent(name), contents: Data())
        }

        try DaemonStampFiles.clear(in: dir)

        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir)), ["last_sync.json", "watchtower.db"])
        XCTAssertNoThrow(try DaemonStampFiles.clear(in: dir), "missing stamps are fine")
    }
}

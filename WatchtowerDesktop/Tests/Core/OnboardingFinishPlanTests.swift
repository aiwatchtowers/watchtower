import XCTest
@testable import WatchtowerCore

@MainActor
final class OnboardingFinishPlanTests: XCTestCase {
    private final class Daemon: OnboardingDaemonControl {
        var running: Bool
        var calls: [String] = []
        init(running: Bool) { self.running = running }
        func daemonIsRunning() -> Bool { running }
        func startDaemon() async { calls.append("start") }
        func restartDaemon() async { calls.append("restart") }
    }

    func testStartsAStoppedDaemonAndRestartsARunningOne() async {
        let stopped = Daemon(running: false)
        await OnboardingFinishPlan.bringUpDaemon(stopped)
        XCTAssertEqual(stopped.calls, ["start"])

        let running = Daemon(running: true)
        await OnboardingFinishPlan.bringUpDaemon(running)
        XCTAssertEqual(running.calls, ["restart"])
    }

    func testLanding() {
        let slack = ConnectedSources(slack: true)
        let mail = ConnectedSources(mail: true)
        let none = ConnectedSources()
        XCTAssertEqual(OnboardingFinishPlan.landing(goals: [.workCommunication], connected: slack), .catchUp)
        XCTAssertEqual(OnboardingFinishPlan.landing(goals: [.workCommunication], connected: mail), .catchUp)
        XCTAssertEqual(OnboardingFinishPlan.landing(goals: [.workCommunication, .development], connected: none), .workbench,
                       "no Catch-Up tab without Slack or mail")
        XCTAssertEqual(OnboardingFinishPlan.landing(goals: [.development, .meetings], connected: slack), .workbench)
        XCTAssertEqual(OnboardingFinishPlan.landing(goals: [.tasksAndJira, .meetings], connected: slack), .chat)
        XCTAssertEqual(OnboardingFinishPlan.landing(goals: [], connected: none), .chat)
    }

    private func progress(active: Bool, updated: Date) throws -> SyncProgress {
        let stamp = ISO8601DateFormatter().string(from: updated)
        let json = #"{"active":\#(active),"phase":"Messages","detail":"34/105 channels","messages_fetched":120,"updated_at":"\#(stamp)"}"#
        return try JSONDecoder().decode(SyncProgress.self, from: Data(json.utf8))
    }

    func testFirstSyncTextWhileSyncing() throws {
        let now = Date()
        let text = OnboardingFinishPlan.firstSyncText(progress: try progress(active: true, updated: now), historyDays: 7, now: now)
        XCTAssertEqual(text?.title, "Syncing Slack for the last 7 days — usually 3–5 min")
        XCTAssertEqual(text?.detail, "Messages · 34/105 channels")
        XCTAssertEqual(
            OnboardingFinishPlan.firstSyncText(progress: try progress(active: true, updated: now), historyDays: 1, now: now)?.title,
            "Syncing Slack for the last day — usually 3–5 min"
        )
    }

    func testNoFirstSyncTextWhenIdleOrStale() throws {
        let now = Date()
        XCTAssertNil(OnboardingFinishPlan.firstSyncText(progress: nil, historyDays: 2, now: now))
        XCTAssertNil(OnboardingFinishPlan.firstSyncText(progress: try progress(active: false, updated: now), historyDays: 2, now: now))
        let stale = try progress(active: true, updated: now.addingTimeInterval(-SyncProgress.staleAfter - 60))
        XCTAssertNil(OnboardingFinishPlan.firstSyncText(progress: stale, historyDays: 2, now: now))
    }
}

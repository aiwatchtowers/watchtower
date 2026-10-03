import XCTest
import WatchtowerCore

final class SessionAgentStatusTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 1_790_000_000)

    private func stamp(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: started.addingTimeInterval(offset))
    }

    private func effective(
        _ stored: SessionAgentState?, at: String?, startedAt: Date?
    ) -> SessionSwitcherPresentation.State {
        SessionAgentStatus.effective(stored: stored, storedAt: at, startedAt: startedAt)
    }

    /// PROJ-11: a state written during an earlier process run (before the
    /// current `startedAt`) never shows — Restart, relaunch or an app
    /// restart start at plain running until the new run's first hook.
    func testProj11_StateFromAnEarlierRunIsIgnored() {
        for stored in [SessionAgentState.working, .waiting, .approval] {
            XCTAssertEqual(effective(stored, at: stamp(-0.001), startedAt: started), .running,
                           "\(stored) from the earlier run is not trusted")
        }
        XCTAssertEqual(effective(.waiting, at: stamp(30), startedAt: nil), .running,
                       "no known start time: nothing is trusted")
        XCTAssertEqual(effective(.waiting, at: "2026-10-03 12:34:56", startedAt: started), .running,
                       "an unreadable stamp is not trusted")
    }

    func testLiveStateOfThisRunIsShown() {
        XCTAssertEqual(effective(.working, at: stamp(1), startedAt: started), .working)
        XCTAssertEqual(effective(.waiting, at: stamp(1), startedAt: started), .waitingForOwner)
        XCTAssertEqual(effective(.approval, at: stamp(1), startedAt: started), .needsApproval)
        XCTAssertEqual(effective(.waiting, at: stamp(0), startedAt: started), .waitingForOwner,
                       "a state stamped at the start instant counts")
    }

    func testNullStateIsPlainRunning() {
        XCTAssertEqual(effective(nil, at: nil, startedAt: started), .running)
        XCTAssertEqual(effective(nil, at: stamp(5), startedAt: started), .running)
    }

    func testStampParsesAsUTCWhateverTheProcessTimeZone() throws {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let parsed = try XCTUnwrap(SessionAgentStatus.parseStamp("2026-10-03T12:34:56.789Z"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: parsed)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second],
                       [2026, 10, 3, 12, 34, 56])
        XCTAssertEqual(Double(parts.nanosecond ?? 0) / 1e6, 789, accuracy: 1)
        XCTAssertNil(SessionAgentStatus.parseStamp(""))
    }

    func testResolveKeepsOnlyLiveRowsAndTheTrustedStamp() {
        let rows = [
            SessionAgentStateRow(id: 1, projectID: 7, title: "One", agentState: "waiting",
                                 agentStateAt: stamp(2), workbenchName: "acme"),
            SessionAgentStateRow(id: 2, projectID: 7, title: "Two", agentState: "approval",
                                 agentStateAt: stamp(-2), workbenchName: "acme"),
            SessionAgentStateRow(id: 3, projectID: 7, title: "Three", agentState: "waiting",
                                 agentStateAt: stamp(2), workbenchName: "acme"),
            SessionAgentStateRow(id: 4, projectID: 7, title: "Four", agentState: "idle",
                                 agentStateAt: stamp(2), workbenchName: "acme")
        ]
        let statuses = SessionAgentStatus.resolve(
            rows, liveIDs: [1, 2, 4], startedAt: [1: started, 2: started, 4: started]
        )
        XCTAssertEqual(Set(statuses.keys), [1, 2, 4], "a row that is not live is left out")
        XCTAssertEqual(statuses[1], SessionAgentStatus(
            sessionID: 1, workbenchID: 7, workbenchName: "acme", title: "One", state: .waitingForOwner, at: stamp(2)
        ))
        XCTAssertEqual(statuses[2]?.state, .running)
        XCTAssertNil(statuses[2]?.at, "an untrusted state carries no stamp")
        XCTAssertEqual(statuses[4]?.state, .running, "an unknown stored value reads as no state")
    }
}

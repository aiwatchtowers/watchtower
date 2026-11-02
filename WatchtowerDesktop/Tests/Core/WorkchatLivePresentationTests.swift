import XCTest
@testable import WatchtowerCore

final class WorkchatLivePresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func snapshot(
        current: SessionLiveAction? = nil,
        latest: SessionLiveAction? = nil,
        agents: [SessionLiveAgent] = [],
        state: String = "known",
        active: Bool = true
    ) -> SessionFeedLive {
        SessionFeedLive(observedAt: now, turnAt: now - 60, turnActive: active, current: current, latest: latest,
                        agents: agents, agentsState: state)
    }
    private func row(
        _ live: SessionFeedLive?,
        error: String? = nil,
        loaded: Bool = true,
        working: Bool = true,
        age: TimeInterval = 0
    ) -> WorkchatLivePresentation.Row? {
        WorkchatLivePresentation.row(snapshot: live, error: error, loaded: loaded, working: working, stateAt: now - 5, now: now + age)
    }
    func testCurrentOrLastOneLineAndDifferentTimers() throws {
        let action = SessionLiveAction(id: "t", tool: "Read", summary: "SessionFeed.swift", startedAt: now - 12, more: 2)
        let current = try XCTUnwrap(row(snapshot(current: action)))
        XCTAssertEqual(current.text, "SessionFeed.swift · 2 more")
        XCTAssertEqual(current.elapsed, "0:12")
        XCTAssertTrue(current.pulse)
        let last = try XCTUnwrap(row(snapshot(latest: action)))
        XCTAssertEqual(last.text, "Last · SessionFeed.swift")
        XCTAssertEqual(last.elapsed, "1:00", "completed action timer must stop; this is the turn timer")
        XCTAssertFalse(last.pulse)
        XCTAssertNil(row(snapshot(current: action), working: false))
    }
    func testLoadingLegacyUnknownAndFallbackCopy() {
        XCTAssertEqual(row(nil, loaded: false)?.text, "Loading activity…")
        XCTAssertEqual(row(nil)?.text, "Activity unavailable")
        XCTAssertEqual(row(snapshot())?.text, "Working…")
        XCTAssertNil(row(snapshot())?.agentsBadge)
        XCTAssertEqual(row(snapshot(state: "unknown"))?.agentsBadge, "?")
        XCTAssertEqual(WorkchatLivePresentation.retryTitle, "Retry")
        XCTAssertEqual(WorkchatLivePresentation.agentsHelp, "Show running agents")
        XCTAssertEqual(WorkchatLivePresentation.unknownAgents, "Agent status unavailable")
        XCTAssertEqual(WorkchatLivePresentation.agentsTitle(count: 3), "Running agents · 3")
        XCTAssertEqual(WorkchatLivePresentation.moreAgents(4), "4 more agents")
    }
    func testErrorAndStaleFreezeTimersIncludingAnOpenPicker() throws {
        let agent = SessionLiveAgent(ref: SessionFeedSubagent(toolUseID: "a", status: "running"), startedAt: now - 20)
        let live = snapshot(current: SessionLiveAction(tool: "Bash", summary: "go test", startedAt: now - 2), agents: [agent])
        XCTAssertNotNil(row(live, age: 9)?.elapsed)
        let stale = try XCTUnwrap(row(live, age: 10))
        XCTAssertEqual(stale.text, "Activity out of date · 10s ago")
        XCTAssertNil(stale.elapsed); XCTAssertFalse(stale.pulse); XCTAssertFalse(stale.agentsEnabled)
        XCTAssertTrue(stale.retry); XCTAssertTrue(stale.warning); XCTAssertEqual(stale.agentsBadge, "?")
        XCTAssertTrue(WorkchatLivePresentation.agentRows(live, now: now + 10).isEmpty, "an already open picker must not show running clocks")
        XCTAssertTrue(WorkchatLivePresentation.agentRows(live, error: "read failed", now: now).isEmpty)
        let failed = try XCTUnwrap(row(live, error: "read failed"))
        XCTAssertEqual(failed.text, "Activity unavailable"); XCTAssertNil(failed.elapsed); XCTAssertFalse(failed.pulse)
    }
    func testMainCompletionRetainsBackgroundAgentsAndFinishedAreHidden() {
        let ref = SessionFeedSubagent(toolUseID: "a", type: "Codex", description: "Check parser", status: "running")
        let running = SessionLiveAgent(
            ref: ref,
            startedAt: now - 90,
            action: SessionLiveAction(tool: "Read", summary: "Read fixture"),
            canOpen: true
        )
        let done = SessionLiveAgent(ref: SessionFeedSubagent(toolUseID: "b", status: "finished"))
        let live = snapshot(agents: [running, done], active: false)
        XCTAssertEqual(row(live)?.agentsBadge, "1")
        XCTAssertEqual(row(live)?.text, "Working…")
        let rows = WorkchatLivePresentation.agentRows(live, now: now)
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.title, "Check parser")
        XCTAssertEqual(rows.first?.action, "Read fixture"); XCTAssertEqual(rows.first?.elapsed, "1:30")
        XCTAssertTrue(rows.first?.agent.canOpen == true)
        let unknown = snapshot(agents: [SessionLiveAgent(ref: SessionFeedSubagent(toolUseID: "c"))])
        XCTAssertEqual(row(unknown)?.agentsBadge, "?")
        XCTAssertEqual(WorkchatLivePresentation.agentRows(unknown, now: now).first?.action, "Agent status unavailable")
    }
    func testMissingTimesNeverInventTimersAndClockSkewClamps() throws {
        let raw = #"{"observed_at":"2026-11-02T10:00:00Z","turn_at":"0001-01-01T00:00:00Z","turn_active":true,"#
            + #""current":null,"latest":null,"agents":[],"agents_state":"known","agents_more":0}"#
        let value = try JSONDecoder().decode(SessionFeedLive.self, from: Data(raw.utf8))
        XCTAssertNil(value.turnAt); XCTAssertNotNil(value.observedAt)
        XCTAssertNil(WorkchatLivePresentation.elapsed(from: nil, now: now))
        XCTAssertEqual(WorkchatLivePresentation.elapsed(from: now + 100, now: now), "0:00")
    }
}

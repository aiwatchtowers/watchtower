import WatchtowerChatText
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The phone's agents list (#2065, spec §2): subagent entries leave the dialog and sort into Working and Done.
final class WorkchatAgentsTests: XCTestCase {
    private func owner(_ id: String) -> SessionChat.Entry { SessionChat.Entry(id: id, kind: .owner, text: "hi") }
    private func agent(_ id: String) -> SessionChat.Entry { SessionChat.Entry(id: id, kind: .agent, text: "ok") }

    private func marker(_ id: String, _ status: String, ids: Bool = true) -> SessionChat.Entry {
        SessionChat.Entry(
            id: id, kind: .subagent, text: "",
            subagent: .init(
                agentID: ids ? "ag-\(id)" : "", toolUseID: ids ? "tu-\(id)" : "",
                type: "Explore", description: "Look \(id)", status: status
            )
        )
    }

    func testDialogDropsSubagentEntries() {
        XCTAssertEqual(WorkchatAgents.dialog([owner("o1"), marker("s1", "running"), agent("a1")]).map(\.id), ["o1", "a1"])
    }

    func testSectionsFromMarkers() {
        let agents = WorkchatAgents(entries: [marker("w1", "running"), marker("d1", "finished"), marker("d2", "finished")], sessionID: 3)
        XCTAssertEqual(agents.working.map(\.id), ["w1"])
        XCTAssertEqual(agents.done.map(\.id), ["d2", "d1"], "newest first")
        XCTAssertEqual(agents.badge, .working(1))
        XCTAssertFalse(agents.doneOpenByDefault)
    }

    func testOnlyDoneBadgeAndOpen() {
        let agents = WorkchatAgents(entries: [marker("d1", "finished"), marker("d2", "finished")], sessionID: 3)
        XCTAssertEqual(agents.badge, .done(2))
        XCTAssertTrue(agents.doneOpenByDefault)
        XCTAssertEqual(WorkchatAgentsText.doneBadge(2), "✓ 2")
    }

    func testNoAgentsNoButton() {
        XCTAssertNil(WorkchatAgents(entries: [owner("o1"), agent("a1")], sessionID: 3).badge)
    }

    func testUnknownStatusInNeitherSection() {
        let agents = WorkchatAgents(entries: [marker("x", "weird")], sessionID: 3)
        XCTAssertTrue(agents.working.isEmpty)
        XCTAssertTrue(agents.done.isEmpty)
        XCTAssertNil(agents.badge)
    }

    func testRowsRouteToTheAgentsChat() throws {
        let agents = WorkchatAgents(entries: [marker("w1", "running"), marker("w2", "running", ids: false)], sessionID: 3)
        XCTAssertEqual(agents.working[0].route, SessionChatRoute(sessionID: 3, agentID: "ag-w1", toolUseID: "tu-w1"))
        XCTAssertNil(agents.working[1].route)
        XCTAssertEqual(agents.working[0].type, "Explore")
        XCTAssertEqual(agents.working[0].description, "Look w1")
    }

    func testOwnerDoneChoiceSurvivesDefaultChange() {
        let working = WorkchatAgents(entries: [marker("w", "running"), marker("d", "finished")], sessionID: 3)
        let idle = WorkchatAgents(entries: [marker("d", "finished")], sessionID: 3)
        XCTAssertFalse(working.doneIsOpen(.automatic))
        XCTAssertTrue(idle.doneIsOpen(.automatic))
        XCTAssertTrue(working.doneIsOpen(.open), "opened while working, stays open once the default flips")
        XCTAssertTrue(idle.doneIsOpen(.open))
        XCTAssertFalse(idle.doneIsOpen(.closed), "closed by the owner beats the open default")
        XCTAssertFalse(working.doneIsOpen(.closed))
    }

    func testBadgeValue() {
        XCTAssertEqual(WorkchatAgentsText.badgeValue(.working(2)), "2 working")
        XCTAssertEqual(WorkchatAgentsText.badgeValue(.done(3)), "3 done")
    }

    func testStrings() {
        XCTAssertEqual(WorkchatAgentsText.done(9), "Done · 9")
        XCTAssertEqual(WorkchatAgentsText.running, "Running")
        XCTAssertEqual(WorkchatAgentsText.title, "Agents")
        XCTAssertEqual(WorkchatAgentsText.working, "Working")
        XCTAssertEqual(WorkchatAgentsText.close, "Close")
    }

    // MARK: Live rows (#2112 spec §6)

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func liveAgent(
        _ id: String,
        _ status: String,
        action: SessionLiveAction? = nil,
        startedAt: Date? = nil,
        type: String = "Explore",
        canOpen: Bool = true
    ) -> SessionLiveAgent {
        SessionLiveAgent(
            ref: SessionFeedSubagent(toolUseID: "tu-\(id)", agentID: "ag-\(id)", type: type, description: "Look \(id)", status: status),
            startedAt: startedAt, action: action, canOpen: canOpen
        )
    }

    /// The hub's block: `observed_at` is the hub's read time, which the phone never judges.
    private func live(_ agents: [SessionLiveAgent], state: String = "known", more: Int = 0) -> SessionFeedLive {
        SessionFeedLive(observedAt: now.addingTimeInterval(-3600), agents: agents, agentsState: state, agentsMore: more)
    }

    private func agents(
        _ entries: [SessionChat.Entry],
        live: SessionFeedLive?,
        error: String? = nil,
        working: Bool = true,
        tower: WorkchatAgents.Tower = WorkchatAgents.Tower()
    ) -> WorkchatAgents {
        WorkchatAgents(entries: entries, sessionID: 3, live: live, liveError: error, sessionWorking: working, tower: tower, now: now)
    }

    /// A linked tower whose last heartbeat and publish were at `at`.
    private func tower(heartbeatAt at: Date) -> WorkchatAgents.Tower {
        WorkchatAgents.Tower(
            heartbeat: HeartbeatPayload(
                updatedAt: at, appVersion: "1.0", hubID: "hub", macName: "Acme Mac", flavor: .default,
                lastPublishAt: at, lastRelayAt: at, relayBacklog: 0, accounts: [],
                enabledAt: at, ownerUser: "_user", sharing: .none
            ),
            linked: true
        )
    }

    /// The shared projection's rows for the same block, observed now.
    private func shared(_ block: SessionFeedLive, done: [SessionFeedSubagent] = []) -> [WorkchatLivePresentation.AgentRow] {
        var observed = block
        observed.observedAt = now
        return WorkchatLivePresentation.agentsList(snapshot: observed, error: nil, feedLoaded: true, feedError: nil,
                                                   done: done, idle: false, now: now).working
    }

    func testLiveRowsAreTheSharedProjection() throws {
        let grep = SessionLiveAction(tool: "Grep", summary: "func LiveOf", startedAt: now.addingTimeInterval(-2))
        let bash = SessionLiveAction(tool: "Bash", summary: "codex review --base main", startedAt: now.addingTimeInterval(-2))
        let block = live([
            liveAgent("w1", "running", action: grep, startedAt: now.addingTimeInterval(-4)),
            liveAgent("w2", "running", action: bash, startedAt: now.addingTimeInterval(-125), type: "codex-wrapper"),
            liveAgent("w3", "running", type: ""),
            liveAgent("w4", "unknown")
        ])
        let result = agents(["w1", "w2", "w3", "w4"].map { marker($0, "running") }, live: block)
        let expected = shared(block)
        XCTAssertEqual(result.working.map(\.id), expected.map(\.id))
        XCTAssertEqual(result.working.map(\.type), expected.map(\.heading))
        XCTAssertEqual(result.working.map(\.action), expected.map(\.action))
        XCTAssertEqual(result.working.map(\.symbol), expected.map(\.symbol))
        XCTAssertEqual(result.working.map(\.elapsed), expected.map(\.elapsed))
        // The literal shape, as the shared projection words it.
        XCTAssertEqual(result.working.map(\.action), ["func LiveOf", "codex review --base main", "Working…", "Agent status unavailable"])
        XCTAssertEqual(result.working.map(\.elapsed), ["0:04", "2:05", nil, nil])
        XCTAssertEqual(result.working.map(\.description), ["Look w1", "Look w2", "", "Look w4"])
        XCTAssertEqual(result.working[2].type, "Look w3", "no type: the task is the heading")
        XCTAssertEqual(result.working[0].route, SessionChatRoute(sessionID: 3, agentID: "ag-w1", toolUseID: "tu-w1"))
    }

    func testRowsRedrawAtTheTick() {
        let block = live([liveAgent("w1", "running", startedAt: now.addingTimeInterval(-4))])
        let result = agents([marker("w1", "running")], live: block)
        XCTAssertTrue(result.ticks)
        XCTAssertEqual(result.working(at: now.addingTimeInterval(60)).map(\.elapsed), ["1:04"], "fresh tower: never stale")
    }

    func testCannotOpenHasNoRoute() {
        let result = agents([marker("w1", "running")], live: live([liveAgent("w1", "running", canOpen: false)]))
        XCTAssertNil(result.working[0].route)
    }

    func testClockSkewedStartShowsZero() {
        let result = agents([marker("w1", "running")], live: live([liveAgent("w1", "running", startedAt: now.addingTimeInterval(30))]))
        XCTAssertEqual(result.working[0].elapsed, "0:00")
    }

    func testWithoutLiveRowStaysRunning() {
        let result = agents([marker("w1", "running")], live: nil)
        XCTAssertNil(result.working[0].action)
        XCTAssertNil(result.working[0].elapsed)
        XCTAssertFalse(result.ticks)
        XCTAssertEqual(result.badge, .working(1))
    }

    func testMarkerMissingFromAKnownLiveListIsNotWorking() {
        let result = agents([marker("w1", "running"), marker("w2", "running")], live: live([liveAgent("w1", "running")]))
        XCTAssertEqual(result.working.map(\.id), ["tu-w1"])
        XCTAssertEqual(result.badge, .working(1))
    }

    func testBadgeCountsAgentsMoreAsTheSharedRow() {
        let result = agents([marker("w1", "running")], live: live([liveAgent("w1", "running")], more: 3))
        XCTAssertEqual(result.badge, .working(4))
    }

    func testUnknownAgentsStateBadge() {
        let result = agents([marker("w1", "running")], live: live([liveAgent("w1", "running")], state: "unknown"))
        XCTAssertEqual(result.badge, .unknown)
        XCTAssertEqual(WorkchatAgentsText.unknownBadge, "?")
        XCTAssertEqual(WorkchatAgentsText.badgeValue(.unknown), "status unavailable")
        XCTAssertEqual(result.working.map(\.id), ["tu-w1"], "a fresh block still lists what it saw, as on the Mac")
        XCTAssertEqual(result.working[0].action, "Working…")
    }

    func testFinishedInLiveIsDoneAndNotCounted() {
        let result = agents(
            [marker("w1", "running"), marker("w2", "running"), marker("d1", "finished")],
            live: live([liveAgent("w1", "finished"), liveAgent("w2", "running")])
        )
        XCTAssertEqual(result.working.map(\.id), ["tu-w2"])
        XCTAssertEqual(result.done.map(\.id), ["d1", "w1"], "newest first")
        XCTAssertEqual(result.badge, .working(1))
    }

    func testAllFinishedInLiveFlipsBadgeToDone() {
        let result = agents([marker("w1", "running")], live: live([liveAgent("w1", "finished")]))
        XCTAssertTrue(result.working.isEmpty)
        XCTAssertEqual(result.badge, .done(1))
        XCTAssertTrue(result.doneOpenByDefault)
    }

    func testLiveErrorShowsNoStepAndUnknownBadge() {
        let block = live([liveAgent("w1", "running", action: SessionLiveAction(tool: "Bash", summary: "go test"),
                                    startedAt: now.addingTimeInterval(-40))])
        let result = agents([marker("w1", "running")], live: block, error: "Activity unavailable")
        XCTAssertEqual(result.badge, .unknown)
        XCTAssertEqual(result.working.map(\.id), ["w1"], "the markers, as without live")
        XCTAssertNil(result.working[0].action)
        XCTAssertNil(result.working[0].elapsed)
        XCTAssertFalse(result.ticks)
    }

    func testStaleTowerShowsNoFrozenStep() {
        let block = live([liveAgent("w1", "running", action: SessionLiveAction(tool: "Bash", summary: "go test"),
                                    startedAt: now.addingTimeInterval(-40))])
        let result = agents([marker("w1", "running")], live: block, tower: tower(heartbeatAt: now.addingTimeInterval(-2101)))
        XCTAssertEqual(result.badge, .unknown)
        XCTAssertNil(result.working[0].action)
        XCTAssertNil(result.working[0].elapsed)
    }

    func testIdleSessionWithLiveShowsDoneOnly() {
        let result = agents([marker("w1", "running"), marker("d1", "finished")], live: live([]), working: false)
        XCTAssertTrue(result.working.isEmpty)
        XCTAssertEqual(result.badge, .done(1))
    }

    func testTowerGoingStaleWhileTheSheetIsOpen() {
        let block = live([liveAgent("w1", "running", action: SessionLiveAction(tool: "Bash", summary: "go test"),
                                    startedAt: now.addingTimeInterval(-40))])
        let result = agents([marker("w1", "running")], live: block, tower: tower(heartbeatAt: now))
        XCTAssertEqual(result.working.map(\.action), ["go test"], "fresh at t0")
        XCTAssertEqual(result.working.map(\.elapsed), ["0:40"])
        XCTAssertEqual(result.badge, .working(1))
        XCTAssertTrue(result.ticks)
        // The next tick, no redraw from the parent: the heartbeat is now past `heartbeatStaleAfter`.
        let later = now.addingTimeInterval(2101)
        let rows = result.working(at: later)
        XCTAssertEqual(rows.map(\.id), ["w1"], "the markers, as without live")
        XCTAssertNil(rows[0].action)
        XCTAssertNil(rows[0].elapsed)
        XCTAssertEqual(result.badge(at: later), .unknown)
        XCTAssertEqual(WorkchatAgentsText.unknownBadge, "?")
    }

    func testFinishedLiveAgentWithoutMarkerIsDoneOnce() {
        let result = agents(
            [marker("d1", "finished"), marker("w1", "running")],
            live: live([liveAgent("w1", "running"), liveAgent("cut", "finished"), liveAgent("cut", "finished"),
                        liveAgent("d1", "finished")])
        )
        XCTAssertEqual(result.done.map(\.id), ["d1", "tu-cut"], "the markers' first, newest first; the trimmed one once")
        XCTAssertEqual(result.done[1].type, "Explore")
        XCTAssertEqual(result.done[1].description, "Look cut")
        XCTAssertEqual(result.done[1].route, SessionChatRoute(sessionID: 3, agentID: "ag-cut", toolUseID: "tu-cut"))
        XCTAssertEqual(result.working.map(\.id), ["tu-w1"])
        let idle = agents([marker("d1", "finished")], live: live([liveAgent("cut", "finished")]), working: false)
        XCTAssertEqual(idle.badge, .done(2))
    }

    func testSessionNotWorkingShowsNoLiveRows() {
        let block = live([liveAgent("w1", "running", action: SessionLiveAction(tool: "Bash", summary: "go test"),
                                    startedAt: now.addingTimeInterval(-40))])
        let result = agents([marker("w1", "running"), marker("d1", "finished")], live: block, working: false)
        XCTAssertTrue(result.working.isEmpty)
        XCTAssertTrue(result.working(at: now.addingTimeInterval(5)).isEmpty)
        XCTAssertFalse(result.ticks)
        XCTAssertEqual(result.badge, .done(1))
        XCTAssertEqual(result.done.map(\.id), ["d1"])
        XCTAssertTrue(result.doneOpenByDefault)
    }
}

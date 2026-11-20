import XCTest
@testable import WatchtowerChatText

/// The 👥 list (#2065 spec §2): Working from the live snapshot, Done from the
/// feed's finished subagent markers, and the states and copy around them.
final class WorkchatAgentsListTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(agents: [SessionLiveAgent] = [], state: String = "known") -> SessionFeedLive {
        SessionFeedLive(observedAt: now, turnAt: now - 60, agents: agents, agentsState: state)
    }

    private func running(_ id: String) -> SessionLiveAgent {
        SessionLiveAgent(ref: SessionFeedSubagent(toolUseID: id, type: "Explore", description: "Recon", status: "running"),
                         startedAt: now - 30, canOpen: true)
    }

    private func finished(_ id: String, startedAt: Date? = nil, type: String = "Explore", description: String = "d") -> SessionFeedSubagent {
        var ref = SessionFeedSubagent(toolUseID: id, type: type, description: description, status: "finished")
        ref.startedAt = startedAt
        return ref
    }

    private func list(
        _ live: SessionFeedLive? = nil,
        error: String? = nil,
        feedLoaded: Bool = true,
        feedError: String? = nil,
        done: [SessionFeedSubagent] = [],
        idle: Bool = false
    ) -> WorkchatLivePresentation.AgentsList {
        WorkchatLivePresentation.agentsList(snapshot: live, error: error, feedLoaded: feedLoaded, feedError: feedError,
                                            done: done, idle: idle, now: now)
    }

    private var nineDone: [SessionFeedSubagent] { (1...9).map { finished("d\($0)") } }

    func testWorkingExcludesIdsInDone() {
        let live = snapshot(agents: [running("x"), running("y")])
        let result = list(live, done: [finished("x")])
        XCTAssertEqual(result.working.map(\.id), ["y"], "an agent is never shown in both sections")
        XCTAssertEqual(result.done.map(\.id), ["x"])
    }

    func testDoneOpensByItselfWhenWorkingEmptyOrUnknown() {
        XCTAssertTrue(list(snapshot(), done: nineDone).doneOpenByDefault)
        XCTAssertTrue(list(snapshot(state: "unknown"), done: nineDone).doneOpenByDefault)
        XCTAssertFalse(list(snapshot(agents: [running("w1")]), done: nineDone).doneOpenByDefault)
    }

    func testListStrings() {
        let result = WorkchatLivePresentation.agentsList(snapshot: snapshot(), error: nil, feedLoaded: true, feedError: nil,
                                                         done: nineDone, idle: false, now: now)
        XCTAssertEqual(result.doneTitle, "Done · 9"); XCTAssertEqual(result.workingNote, "No agents working")
        XCTAssertEqual(result.state, .ready)
        XCTAssertEqual(WorkchatLivePresentation.listTitle, "Agents"); XCTAssertEqual(WorkchatLivePresentation.workingTitle, "WORKING")
        XCTAssertEqual(WorkchatLivePresentation.maxDoneRows, 5)
        XCTAssertEqual(WorkchatLivePresentation.doneTitle(1), "Done · 1")
        XCTAssertNil(list(snapshot(agents: [running("w1")])).workingNote, "rows speak for themselves")
    }

    func testUnknownWorkingNeverSaysNoneWorking() {
        XCTAssertEqual(list(snapshot(state: "unknown")).workingNote, "Agent status unavailable")
        XCTAssertEqual(list(snapshot(), error: "read failed").workingNote, "Agent status unavailable")
        let stale = SessionFeedLive(observedAt: now - WorkchatLivePresentation.staleAfter, agentsState: "known")
        XCTAssertEqual(list(stale).workingNote, "Agent status unavailable", "a stale snapshot never claims none")
        let unresolved = SessionLiveAgent(ref: SessionFeedSubagent(toolUseID: "u"))
        XCTAssertEqual(list(snapshot(agents: [unresolved])).workingNote, "Agent status unavailable")
    }

    func testLoadingAndErrorStates() {
        let loading = list(feedLoaded: false)
        XCTAssertEqual(loading.state, .loading)
        XCTAssertEqual(WorkchatLivePresentation.listLoading, "Loading agents…")
        let failed = list(feedLoaded: false, feedError: "boom")
        XCTAssertEqual(failed.state, .error)
        XCTAssertEqual(WorkchatLivePresentation.listError, "Couldn’t read the agents")
        XCTAssertEqual(WorkchatLivePresentation.retryTitle, "Retry")
        let kept = list(snapshot(), feedLoaded: true, feedError: "boom", done: [finished("x")])
        XCTAssertEqual(kept.state, .ready, "a later failure keeps Done from the last good read")
        XCTAssertEqual(kept.done.map(\.id), ["x"])
    }

    func testDoneRowTitleTypeSubtitleDescription() {
        let rows = list(snapshot(), done: [finished("a", type: "codex-wrapper", description: "Review the spec"),
                                           finished("b", type: "", description: "No type")]).done
        XCTAssertEqual(rows.map(\.title), ["codex-wrapper", "Subagent"])
        XCTAssertEqual(rows.map(\.subtitle), ["Review the spec", "No type"])
        XCTAssertEqual(rows.first?.ref.toolUseID, "a")
    }

    func testUnknownDoneAgentDoesNotMakeWorkingUnknown() {
        let unresolved = SessionLiveAgent(ref: SessionFeedSubagent(toolUseID: "x"))
        let result = list(snapshot(agents: [unresolved]), done: [finished("x")])
        XCTAssertEqual(result.workingNote, "No agents working", "an agent already Done does not count, as on the badge")
    }

    func testTurnStartBeforeFirstLiveReadIsNotNone() {
        XCTAssertEqual(list(nil, idle: false).workingNote, "Agent status unavailable", "not observed yet is not none")
        XCTAssertEqual(list(nil, idle: true).workingNote, "No agents working", "an idle session with no snapshot")
        let stale = SessionFeedLive(observedAt: now - WorkchatLivePresentation.staleAfter, agentsState: "known")
        XCTAssertEqual(list(stale, idle: true).workingNote, "No agents working", "an idle pane's old read is not a failure")
    }

    func testWorkingRowHeadingAndSubtitle() throws {
        var agent = running("w")
        agent.action = SessionLiveAction(tool: "Grep", summary: "Grep migrations/")
        let row = try XCTUnwrap(list(snapshot(agents: [agent])).working.first)
        XCTAssertEqual(row.heading, "Explore")
        XCTAssertEqual(row.subtitle, "Recon · Grep migrations/")
        XCTAssertEqual(row.elapsed, "0:30")
    }
}

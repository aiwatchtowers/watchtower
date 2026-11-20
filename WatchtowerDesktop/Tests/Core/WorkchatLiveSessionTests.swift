import XCTest
@testable import WatchtowerCore
import WatchtowerChatText

/// The Mac-only half of the live presentation (`WorkchatLivePresentation+Session`):
/// busy from the session state, Done and a subagent's status from the feed's
/// entries — the tests of the shared classes that need Core types. The
/// FEED-03 guard `WorkchatLivePresentationTests` stays whole beside it.
final class WorkchatLiveSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(agents: [SessionLiveAgent] = []) -> SessionFeedLive {
        SessionFeedLive(observedAt: now, turnAt: now - 60, agents: agents, agentsState: "known")
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

    private func marker(_ ref: SessionFeedSubagent) -> SessionFeedEntry {
        SessionFeedEntry(id: "sub-\(ref.toolUseID)", kind: "subagent", subagent: ref)
    }

    private func activity() -> SessionFeedActivity {
        SessionFeedActivity(tool: "Bash", summary: "go test ./...", startedAt: t0)
    }

    private func list(_ live: SessionFeedLive? = nil, done: [SessionFeedSubagent] = [], idle: Bool = false)
        -> WorkchatLivePresentation.AgentsList {
        WorkchatLivePresentation.agentsList(snapshot: live, error: nil, feedLoaded: true, feedError: nil,
                                            done: done, idle: idle, now: now)
    }

    private var nineDone: [SessionFeedSubagent] { (1...9).map { finished("d\($0)") } }

    /// The open subagent's status comes from the feed's current markers,
    /// not the copy pushed onto the path: finished there → no line.
    func testSubagentStatusReadFromTheCurrentMarkers() {
        let pushed = SessionFeedSubagent(toolUseID: "tu1", status: "running")
        func marker(_ id: String, _ status: String) -> SessionFeedEntry {
            SessionFeedEntry(id: id, kind: "subagent", at: nil, text: "",
                             subagent: SessionFeedSubagent(toolUseID: id, status: status))
        }
        let entries = [marker("tu0", "running"), marker("tu1", "finished")]
        let status = SessionFeedSubagent.currentStatus(of: pushed, in: entries)
        XCTAssertEqual(status, "finished")
        XCTAssertNil(WorkchatActivityPresenter.subagentLine(
            activity: activity(), sessionWorking: true, subagentStatus: status, stateAt: t0, lastAgentAt: nil))
        XCTAssertEqual(SessionFeedSubagent.currentStatus(of: pushed, in: [marker("tu0", "finished")]), "running",
                       "not in the feed: the pushed copy")
    }

    func testDoneOrderNewestFirstUndatedLastInCLIOrder() {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let entries = [
            marker(finished("t1002", startedAt: base + 120)),
            marker(finished("a")),
            SessionFeedEntry(id: "owner", kind: "owner", text: "hi"),
            marker(SessionFeedSubagent(toolUseID: "r", status: "running")),
            marker(finished("t1005", startedAt: base + 300)),
            marker(finished("b"))
        ]
        XCTAssertEqual(WorkchatLivePresentation.done(from: entries).map(\.toolUseID), ["t1005", "t1002", "a", "b"])
    }

    func testUnknownStatusMarkerInNeitherSection() {
        let unknown = SessionFeedSubagent(toolUseID: "m", type: "Explore", status: "unknown")
        let done = WorkchatLivePresentation.done(from: [marker(unknown)])
        XCTAssertTrue(done.isEmpty)
        let result = list(snapshot(), done: done)
        XCTAssertTrue(result.working.isEmpty); XCTAssertTrue(result.done.isEmpty)
    }

    /// A session waiting on an approval is busy, not idle: the list reads the
    /// real snapshot and, without one, never claims none works. `idle` is
    /// derived as the view derives it.
    func testPermissionPromptNeverSaysNoneWorking() {
        let approval = SessionSwitcherPresentation.State(kind: .needsApproval, live: true)
        let idle = !WorkchatLivePresentation.busy(approval)
        XCTAssertFalse(idle)
        let waiting = list(nil, done: nineDone, idle: idle)
        XCTAssertEqual(waiting.workingNote, "Agent status unavailable")
        XCTAssertTrue(waiting.doneOpenByDefault)
        let fed = list(snapshot(agents: [running("bg")]), idle: idle)
        XCTAssertEqual(fed.working.map(\.id), ["bg"], "the real snapshot lists the background agent")
        XCTAssertNil(fed.workingNote)
    }

    func testBusyCoversWorkingBackgroundAndApproval() {
        typealias State = SessionSwitcherPresentation.State
        let busy = State.Kind.allCases.filter { WorkchatLivePresentation.busy(State(kind: $0, live: true)) }
        XCTAssertEqual(Set(busy), [.working, .background, .needsApproval])
        XCTAssertFalse(WorkchatLivePresentation.busy(State(kind: .working, live: false)), "a session that is gone is idle")
        XCTAssertFalse(WorkchatLivePresentation.busy(nil))
    }
}

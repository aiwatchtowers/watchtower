import GRDB
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerCore

/// PROJ-11 (amended, ask #1545; spec 2026-11-18 §6.5): a live parent whose
/// own turn ended while a sub-session of it is live shows Sub-sessions
/// working, raises no owner notice and no chat-question escalation, and
/// shows its stored state once the last child stops. Also the agent message
/// left in a prompt (§6.6), read with the states.
final class SubSessionsWorkingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var now: Date { start.addingTimeInterval(600) }

    private func stamp(_ offset: TimeInterval) -> String {
        SessionAgentStatus.formatStamp(start.addingTimeInterval(offset))
    }

    /// The parent (1), waiting at its prompt since its turn ended, and its
    /// sub-session (2), working.
    private func rows(finished: Bool = false, question: Bool = false) -> [SessionAgentStateRow] {
        let ended = stamp(60)
        let parent = SessionAgentStateRow(
            id: 1, projectID: 1, title: "Export reports to PDF", agentState: "waiting", agentStateAt: ended,
            workbenchName: "acme", finishedAt: finished ? ended : nil,
            chatQuestion: question ? #"{"question":"Which format?","options":[]}"# : nil,
            chatQuestionAt: question ? ended : nil
        )
        let child = SessionAgentStateRow(
            id: 2, projectID: 1, title: "PDF export API", agentState: "working", agentStateAt: stamp(120),
            workbenchName: "acme", parentSessionID: 1
        )
        return [parent, child]
    }

    private func resolve(_ rows: [SessionAgentStateRow], live: Set<Int64>) -> [Int64: SessionAgentStatus] {
        SessionAgentStatus.resolve(rows, liveIDs: live, startedAt: [1: start, 2: start], now: now)
    }

    func testParentShowsSubSessionsWorkingWhileAChildIsLive() {
        for finished in [false, true] {
            let parent = resolve(rows(finished: finished), live: [1, 2])[1]
            XCTAssertEqual(parent?.state.kind, .subSessionsWorking, "finished: \(finished)")
            XCTAssertEqual(parent?.state.liveSubSessions, 1)
            XCTAssertEqual(parent?.isAtPrompt, true, "its turn is over: a line may still go in")
        }
    }

    func testProj11_LastChildStopsShowsTheStoredState() {
        XCTAssertEqual(resolve(rows(), live: [1])[1]?.state.kind, .stopped)
        XCTAssertEqual(resolve(rows(finished: true), live: [1])[1]?.state.kind, .finished)
        XCTAssertEqual(resolve(rows(), live: [1])[1]?.state.liveSubSessions, 0)
    }

    func testOwnerWorkIsNeverHiddenBehindChildren() {
        var withAsk = rows()
        withAsk[0].openAsks = 1
        withAsk[0].openQuestionAsks = 1
        XCTAssertEqual(resolve(withAsk, live: [1, 2])[1]?.state.kind, .waitingOnAsk)
        XCTAssertEqual(resolve(rows(), live: [2])[1]?.state.kind, .notStarted, "a parent not running is not waiting")
    }

    func testProj11_NoOwnerPresenceNoticeWhileChildrenWork() throws {
        var notices = SessionAgentNoticePolicy()
        XCTAssertEqual(notices.update(resolve(rows(), live: [1, 2]), canPost: true), [],
                       "no Idle banner while the child works")
        let actions = notices.update(resolve(rows(), live: [1]), canPost: true)
        XCTAssertEqual(actions.count, 1, "the last child stopped: the parent's own stop is announced once")
        if case let .post(notice)? = actions.first {
            XCTAssertEqual(notice.title, "Export reports to PDF is idle")
        } else {
            XCTFail("want a post, got \(actions)")
        }

        let question = rows(question: true)
        let asked = try XCTUnwrap(SessionAgentStatus.parseStamp(stamp(60)))
        func decide(liveChildren: Int) -> ChatQuestionEscalationPolicy.Decision {
            ChatQuestionEscalationPolicy.decide(
                row: question[0], live: true, startedAt: start, presence: .away(since: asked.addingTimeInterval(-1)),
                hasOwnerDraft: false, now: now,
                liveChildren: SessionAgentStatus.liveChildren(question, liveIDs: liveChildren > 0 ? [1, 2] : [1])[1] ?? 0
            )
        }
        XCTAssertEqual(decide(liveChildren: 1), .none, "no escalation while a child works")
        XCTAssertEqual(decide(liveChildren: 0), .escalate(.away), "the owner was away: raised once the child stopped")
    }

    /// Background shells alone (a dev server) do not hide the wait on a
    /// child, and no stop banner comes while it works (Go `Resolve`, the
    /// shared fixture's shells case).
    func testShellsOnlyParentWaitsOnItsChildWithoutANotice() {
        var shells = rows()
        shells[0].agentBackground = 0
        shells[0].agentBackgroundShells = 1
        shells[0].agentBackgroundAt = stamp(60)
        XCTAssertEqual(resolve(shells, live: [1, 2])[1]?.state.kind, .subSessionsWorking)
        var notices = SessionAgentNoticePolicy()
        XCTAssertEqual(notices.update(resolve(shells, live: [1, 2]), canPost: true), [])
        XCTAssertEqual(resolve(shells, live: [1])[1]?.state.kind, .background, "the child stopped: the shells show")
        XCTAssertEqual(notices.update(resolve(shells, live: [1]), canPost: true).count, 1,
                       "the turn's stop is announced once the child ends")
    }

    func testSubSessionsWorkingPresentation() {
        let state = SessionSwitcherPresentation.State.live(.subSessionsWorking, liveSubSessions: 2)
        XCTAssertEqual(SessionStatePresentation.caption(for: state), "Sub-sessions working")
        XCTAssertEqual(SessionStatePresentation.subSessionsWorkingCaption, "Sub-sessions working")
        XCTAssertEqual(SessionStatePresentation.glyph(for: state), "hourglass", "as Agents working with shells only")
        XCTAssertEqual(SessionStatePresentation.color(for: state), .green)
        XCTAssertEqual(SessionNestingPresentation.subSessionsSuffix(state.liveSubSessions), "· 2 sub-sessions")
        XCTAssertFalse(SessionDeletePolicy.isQuick(state, isWorkbenchSession: true), "children may still report to it")
        XCTAssertEqual(SessionPanelSections.panelSection(of: state), .main, "never folded away while its children work")
    }

    // MARK: - The agent message in the prompt (§6.6)

    func testMessageFlagShowsWhileAnyRowIsUncleared() throws {
        let db = try TestDatabase.create()
        let bench = try db.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: "/tmp/acme") }
        let (a, b, c) = try db.write { db in
            let make = {
                try TerminalSessionQueries.create(db, .init(
                    projectID: bench, kind: .claude, title: "s", folderPath: "/tmp/acme", claudeSessionID: UUID().uuidString
                )).id
            }
            return (try make(), try make(), try make())
        }
        func message(to: Int64, reason: String, cleared: Bool) throws {
            try db.write { db in
                try db.execute(sql: """
                    INSERT INTO session_messages (workbench_id, from_session_id, to_session_id, kind, text, state, reason,
                                                  prompt_cleared_at)
                    VALUES (?, ?, ?, 'message', 'look at hub', 'delivered', ?, ?)
                    """, arguments: [bench, a, to, reason, cleared ? "2026-11-18T00:00:00Z" : nil])
            }
        }
        try message(to: b, reason: SessionMessage.typedNotSubmitted, cleared: true)
        try message(to: b, reason: SessionMessage.typedNotSubmitted, cleared: false)
        try message(to: c, reason: SessionMessage.typedNotSubmitted, cleared: true)
        try message(to: a, reason: "", cleared: false)
        let rows = try db.read { try TerminalSessionQueries.fetchAgentStates($0, liveIDs: []) }
        let statuses = SessionAgentStatus.resolve(rows, liveIDs: [], startedAt: [:], now: now)
        XCTAssertEqual(statuses[b]?.messageInPrompt, true, "one uncleared row is enough")
        XCTAssertEqual(statuses[c]?.messageInPrompt, false, "every row cleared")
        XCTAssertEqual(statuses[a]?.messageInPrompt, false, "a submitted message is no flag")
        let ids = try db.read { try SessionMessageQueries.waitingInPromptIDs($0, sessionID: b) }
        XCTAssertEqual(ids.count, 1)
    }

    func testStateRowsCarryTheParent() throws {
        let db = try TestDatabase.create()
        let bench = try db.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: "/tmp/acme") }
        let (parent, child) = try db.write { db in
            let parent = try TerminalSessionQueries.create(
                db, .init(projectID: bench, kind: .claude, title: "p", folderPath: "/tmp/acme", claudeSessionID: "p")
            ).id
            let child = try TerminalSessionQueries.create(
                db, .init(projectID: bench, kind: .claude, title: "c", folderPath: "/tmp/acme", claudeSessionID: "c")
            ).id
            try db.execute(sql: "UPDATE terminal_sessions SET parent_session_id = ? WHERE id = ?", arguments: [parent, child])
            return (parent, child)
        }
        let rows = try db.read { try TerminalSessionQueries.fetchAgentStates($0, liveIDs: []) }
        XCTAssertEqual(rows.first { $0.id == child }?.parentSessionID, parent)
        XCTAssertEqual(SessionAgentStatus.liveChildren(rows, liveIDs: [child]), [parent: 1])
        XCTAssertEqual(SessionAgentStatus.liveChildren(rows, liveIDs: [parent]), [:], "a child not running is not live")
    }
}

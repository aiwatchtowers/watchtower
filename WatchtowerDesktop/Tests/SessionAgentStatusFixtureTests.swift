import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// The Go twin `internal/sessionstate` resolves the same rows to the same
/// states: both read `internal/sessionstate/testdata/status_cases.json`.
/// Lives in the Desktop test target (not Tests/Core) because `SessionControl`,
/// whose `isIdle`/`isWorking` the Go predicates mirror, is an app type.
@MainActor
final class SessionAgentStatusFixtureTests: XCTestCase {
    private struct Fixture: Decodable {
        let now: String
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let row: Row
        let expect: Expect
    }

    private struct Row: Decodable {
        let agentState: String?
        let agentStateAt: String?
        let finishedAt: String?
        let agentFailedAt: String?
        let agentBackground: Int?
        let agentBackgroundAt: String?
        let openAsks: Int
        let openQuestionAsks: Int
        let openReviewAsks: Int
        let runStartedAt: String

        enum CodingKeys: String, CodingKey {
            case agentState = "agent_state", agentStateAt = "agent_state_at", finishedAt = "finished_at"
            case agentFailedAt = "agent_failed_at", agentBackground = "agent_background"
            case agentBackgroundAt = "agent_background_at", openAsks = "open_asks"
            case openQuestionAsks = "open_question_asks", openReviewAsks = "open_review_asks"
            case runStartedAt = "run_started_at"
        }
    }

    private struct Expect: Decodable {
        let state: String
        let hooksReported: Bool
        let idle: Bool
        let working: Bool
        let needsApproval: Bool

        enum CodingKeys: String, CodingKey {
            case state, idle, working
            case hooksReported = "hooks_reported", needsApproval = "needs_approval"
        }
    }

    func testEveryGoFixtureCaseResolvesTheSame() throws {
        // Tests/<this file> -> the repository root, three levels up.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("internal/sessionstate/testdata/status_cases.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let now = try XCTUnwrap(SessionAgentStatus.parseStamp(fixture.now))
        XCTAssertFalse(fixture.cases.isEmpty)

        for item in fixture.cases {
            let row = item.row
            let live = !row.runStartedAt.isEmpty
            let started = live ? SessionAgentStatus.parseStamp(row.runStartedAt) : nil
            let stateRow = SessionAgentStateRow(
                id: 1, projectID: 1, title: "t", agentState: row.agentState, agentStateAt: row.agentStateAt,
                workbenchName: "wb", finishedAt: row.finishedAt, agentFailedAt: row.agentFailedAt,
                openAsks: row.openAsks, openQuestionAsks: row.openQuestionAsks, openReviewAsks: row.openReviewAsks,
                agentBackground: row.agentBackground, agentBackgroundAt: row.agentBackgroundAt
            )
            let status = try XCTUnwrap(SessionAgentStatus.resolve(
                [stateRow], liveIDs: live ? [1] : [], startedAt: started.map { [1: $0] } ?? [:], now: now
            )[1], item.name)
            XCTAssertEqual(Self.name(of: status), item.expect.state, item.name)
            XCTAssertEqual(status.hooksReported, item.expect.hooksReported, item.name)
            XCTAssertEqual(SessionControl.isIdle(status), item.expect.idle, item.name)
            XCTAssertEqual(SessionControl.isWorking(status), item.expect.working, item.name)
            XCTAssertEqual(status.state.kind == .needsApproval, item.expect.needsApproval, item.name)
        }
    }

    /// Go's state names; `marked_idle` is a running session holding only the
    /// run's mark.
    private static func name(of status: SessionAgentStatus) -> String {
        switch status.state.kind {
        case .notStarted: return "not_started"
        case .running: return status.runMarked ? "marked_idle" : "running"
        case .working: return "working"
        case .needsApproval: return "needs_approval"
        case .failed: return "error"
        case .waitingOnAsk: return "waiting_for_you"
        case .stopped: return "stopped"
        case .finished: return "finished"
        case .background: return "agents_working"
        case .readyToCheck: return "ready_to_check"
        }
    }
}

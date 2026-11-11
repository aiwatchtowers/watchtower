import GRDB
import XCTest
@testable import WatchtowerCore

/// Where the tuning chat's proposal cards sit in the feed: under the turn whose
/// `propose_tuning_edit` call filed them, else at the end (Task 5.6, #1517).
final class TuningFeedCardsTests: XCTestCase {
    private func action(
        id: Int64,
        tool: String = TuningFeedCards.proposeTool,
        turn: String,
        status: String = "applied",
        result: String
    ) -> AgentAction {
        AgentAction(row: Row([
            "id": id, "tool": tool, "args_json": "{}", "status": status, "turn_id": turn,
            "result_json": result, "surface": "tuning", "conversation_id": 12
        ]))
    }

    private func proposal(id: Int64) throws -> CoachProposal {
        let obj: [String: Any] = [
            "id": id, "title": "t", "why": "w", "destination": "session", "workbench_id": 1,
            "prompt_id": "", "kind": "add", "metric": "corrections", "before": "", "after": "",
            "evidence": [], "sources": 3, "status": "open", "created_at": "2026-11-01T00:00:00Z",
            "verdict": "", "reverts_id": 0, "budget": 0, "decided_at": NSNull(), "baseline": NSNull(),
            "verdict_value": NSNull(), "verdict_at": NSNull(), "origin": "chat", "conversation_id": 12
        ]
        return try JSONDecoder().decode(CoachProposal.self, from: JSONSerialization.data(withJSONObject: obj))
    }

    func testProposalAnchorsToItsTurn() throws {
        let cards = TuningFeedCards.build(
            actions: [action(id: 1, turn: "t1", result: #"{"proposal_id":21,"status":"open"}"#)],
            proposals: [try proposal(id: 21)]
        )
        XCTAssertEqual(cards.byTurn["t1"], [.proposal(21)])
        XCTAssertEqual(cards.trailing, [])
    }

    func testTwoProposalsInOneTurnKeepTheCallOrder() {
        let cards = TuningFeedCards.build(
            actions: [
                action(id: 5, turn: "t1", result: #"{"proposal_id":30}"#),
                action(id: 4, turn: "t1", result: #"{"proposal_id":29}"#)
            ],
            proposals: []
        )
        XCTAssertEqual(cards.byTurn["t1"], [.proposal(29), .proposal(30)])
    }

    func testFailedProposalCallAddsNoCard() {
        let cards = TuningFeedCards.build(
            actions: [
                action(id: 1, turn: "t1", status: "failed", result: ""),
                action(id: 2, turn: "t2", status: "failed", result: #"{"proposal_id":7}"#)
            ],
            proposals: []
        )
        XCTAssertEqual(cards.byTurn, [:])
        XCTAssertEqual(cards.trailing, [])
    }

    func testOtherToolsAndUnreadableResultsAddNoCard() {
        let cards = TuningFeedCards.build(
            actions: [
                action(id: 1, tool: "send_slack_message", turn: "t1", result: #"{"proposal_id":3}"#),
                action(id: 2, turn: "t2", result: #"{"status":"open"}"#),
                action(id: 3, turn: "t3", result: "not json"),
                action(id: 4, turn: "", result: #"{"proposal_id":5}"#)
            ],
            proposals: []
        )
        XCTAssertEqual(cards.byTurn, [:])
        XCTAssertEqual(cards.trailing, [])
    }

    func testUnanchoredGoTrailing() throws {
        let cards = TuningFeedCards.build(
            actions: [action(id: 1, turn: "t1", result: #"{"proposal_id":21}"#)],
            proposals: [try proposal(id: 21), try proposal(id: 22), try proposal(id: 23)]
        )
        XCTAssertEqual(cards.byTurn["t1"], [.proposal(21)])
        XCTAssertEqual(cards.trailing, [.proposal(22), .proposal(23)])
    }

    func testNothingListedTwice() throws {
        let cards = TuningFeedCards.build(
            actions: [
                action(id: 1, turn: "t1", result: #"{"proposal_id":21}"#),
                action(id: 2, turn: "t2", result: #"{"proposal_id":21}"#)
            ],
            proposals: [try proposal(id: 21), try proposal(id: 21)]
        )
        XCTAssertEqual(cards.byTurn, ["t1": [.proposal(21)]])
        XCTAssertEqual(cards.trailing, [])
    }

    func testCardIdentity() {
        XCTAssertEqual(TuningCard.proposal(21).id, "proposal-21")
    }
}

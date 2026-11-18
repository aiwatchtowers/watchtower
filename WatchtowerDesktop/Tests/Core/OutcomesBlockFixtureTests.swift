import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// `AgentActionFeed.outcomesBlock(after:)`'s parts — the floor's formatter,
/// `AgentActionQueries.fetchDecidedAfter` and
/// `AgentToolsContract.actionsSinceLastTurnBlock` — over Go's
/// `internal/chatstore/testdata/outcomes_block_cases.json`, which
/// `TestOutcomesBlock_SharedCases` runs against the hub's port.
@MainActor
final class OutcomesBlockFixtureTests: XCTestCase {
    func testOutcomesBlockMatchesTheGoPort() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/chatstore/testdata/outcomes_block_cases.json")
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 6)
        for tc in cases {
            let name = tc["name"] as? String ?? "?"
            let queue = try TestDatabase.create()
            // The floor's formatter is main-actor isolated: format it here.
            let floor = (tc["after"] as? Double).map { AgentActionFeed.timestampString(Date(timeIntervalSince1970: $0)) }
            let block = try queue.write { db -> String? in
                for r in tc["rows"] as? [[String: Any]] ?? [] {
                    try db.execute(sql: """
                        INSERT INTO agent_actions (id, tool, args_json, conversation_id, status, result_json, error,
                            created_at, decided_at, applied_at)
                        VALUES (?, ?, '{}', ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [r["id"] as? Int64, r["tool"] as? String, r["conversation_id"] as? Int64,
                                         r["status"] as? String, r["result_json"] as? String, r["error"] as? String,
                                         r["created_at"] as? String, r["decided_at"] as? String, r["applied_at"] as? String])
                }
                guard let floor else { return nil }
                let decided = try AgentActionQueries.fetchDecidedAfter(
                    db, conversationID: tc["conversation_id"] as? Int64 ?? 0, after: floor)
                return AgentToolsContract.actionsSinceLastTurnBlock(decided)
            }
            XCTAssertEqual(block, tc["expect"] as? String, name)
        }
    }
}

import XCTest
@testable import WatchtowerCore

final class CoachDecodingTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    func testStatusDecodes() throws {
        let s = try JSONDecoder().decode(CoachStatus.self, from: fixture("coach-status"))
        XCTAssertTrue(s.ok)
        XCTAssertEqual(s.open, 2)
        XCTAssertEqual(s.period.since, "2026-10-14T00:00:00Z")
        XCTAssertEqual(s.metrics.corrections.value, 2.1)
        XCTAssertNil(s.metrics.taskHours.value)
        XCTAssertNil(s.metrics.taskHours.previous)
        XCTAssertFalse(s.metrics.taskHours.known)
        XCTAssertEqual(s.metrics.ownerLoop.previous, 0.31)
        XCTAssertEqual(s.lastRun, "2026-10-25T09:00:00Z")
    }

    func testProposalsDecode() throws {
        let list = try JSONDecoder().decode(CoachProposalList.self, from: fixture("coach-proposals"))
        XCTAssertEqual(list.proposals.count, 2)
        let open = list.proposals[0]
        XCTAssertEqual(open.workbenchID, 0)
        XCTAssertEqual(open.budget, 1000)
        XCTAssertEqual(open.evidence.map(\.ref), ["ask:12", "sess-acme-1"])
        XCTAssertNil(open.decidedAt)
        XCTAssertNil(open.baseline)
        let done = list.proposals[1]
        XCTAssertEqual(done.workbenchID, 3)
        XCTAssertEqual(done.baseline, 3.0)
        XCTAssertEqual(done.verdictValue, 2.1)
        XCTAssertEqual(done.verdictAt, "2026-10-25T09:00:00Z")
    }

    private func decodeProposal(_ extra: String) throws -> CoachProposal {
        let json = """
            {"id":9,"title":"t","why":"w","destination":"claude_skill_user","workbench_id":0,"prompt_id":"",\
            "kind":"add","metric":"corrections","before":"","after":"x","evidence":[],"sources":1,\
            "status":"open","created_at":"2026-11-01T09:00:00Z","decided_at":null,"baseline":null,\
            "verdict":"","verdict_value":null,"verdict_at":null,"reverts_id":0,"budget":0\(extra)}
            """
        return try JSONDecoder().decode(CoachProposal.self, from: Data(json.utf8))
    }

    func testChatProposalKeys() throws {
        let chat = try decodeProposal(#","origin":"chat","skill":"review-pr","conversation_id":12"#)
        XCTAssertEqual(chat.origin, "chat")
        XCTAssertEqual(chat.skill, "review-pr")
        XCTAssertEqual(chat.conversationID, 12)
        XCTAssertNil(chat.folderBranch)

        let old = try decodeProposal("")
        XCTAssertEqual(old.origin, "weekly")
        XCTAssertNil(old.conversationID)
        XCTAssertNil(old.folderBranch)
        XCTAssertEqual(old.writtenBranch, "")
        XCTAssertNil(old.measureFrom)

        let weekly = try decodeProposal(#","origin":"weekly","skill":"","conversation_id":null"#)
        XCTAssertEqual(weekly.origin, "weekly")
        XCTAssertNil(weekly.conversationID)

        let repo = try decodeProposal(
            #","folder_branch":"feature/x","written_branch":"main","measure_from":"2026-11-02T09:00:00Z""#)
        XCTAssertEqual(repo.folderBranch, "feature/x")
        XCTAssertEqual(repo.writtenBranch, "main")
        XCTAssertEqual(repo.measureFrom, "2026-11-02T09:00:00Z")
        XCTAssertEqual(try decodeProposal(#","folder_branch":"""#).folderBranch, "")
    }

    /// The context actions' keys (`cmd/coach.go`, Task 7); an older CLI
    /// sends none and they decode to their defaults.
    func testContextActionKeys() throws {
        let row = try decodeProposal(
            #","session_id":41,"source_key":"acme-tools@example-market","via_session":true,"# +
            #""session_branch":"wt/slim-claude-md","pr":17,"pr_state":"open","# +
            #""pr_url":"https://github.com/acme/app/pull/17","verdict_sessions":12"#)
        XCTAssertEqual(row.verdictSessions, 12)
        XCTAssertEqual(row.sessionID, 41)
        XCTAssertEqual(row.sourceKey, "acme-tools@example-market")
        XCTAssertTrue(row.viaSession)
        XCTAssertEqual(row.sessionBranch, "wt/slim-claude-md")
        XCTAssertEqual(row.pr, 17)
        XCTAssertEqual(row.prState, "open")
        XCTAssertEqual(row.prURL, "https://github.com/acme/app/pull/17")

        let nulls = try decodeProposal(
            #","session_id":null,"source_key":"","via_session":false,"session_branch":"","pr":null,"# +
            #""pr_state":null,"pr_url":null"#)
        XCTAssertNil(nulls.sessionID)
        XCTAssertNil(nulls.pr)
        XCTAssertNil(nulls.prState)
        XCTAssertNil(nulls.prURL)
        XCTAssertEqual(try decodeProposal(#","verdict_sessions":0"#).verdictSessions, 0)

        let old = try decodeProposal("")
        XCTAssertNil(old.sessionID)
        XCTAssertEqual(old.sourceKey, "")
        XCTAssertFalse(old.viaSession)
        XCTAssertEqual(old.sessionBranch, "")
        XCTAssertNil(old.pr)
        XCTAssertNil(old.prState)
        XCTAssertNil(old.prURL)
        XCTAssertNil(old.verdictSessions)
    }

    func testContextDestinationLabels() throws {
        func label(_ dest: String, _ wb: Int64, source: String) throws -> String {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.minimal.utf8)) as? [String: Any])
            json["destination"] = dest
            json["workbench_id"] = wb
            json["source_key"] = source
            return try JSONDecoder().decode(CoachProposal.self, from: JSONSerialization.data(withJSONObject: json))
                .destinationLabel
        }
        XCTAssertEqual(try label("claude_plugin_off", 0, source: "acme-tools@example-market"),
                       "Claude Code plugin · acme-tools@example-market")
        XCTAssertEqual(try label("claude_mcp_server_off", 0, source: "example-server"),
                       "Claude Code MCP server · example-server")
        XCTAssertEqual(try label("claude_connectors_off", 0, source: "connectors"), "Claude Code · claude.ai connectors")
        XCTAssertEqual(try label("claude_memory_index", 3, source: "memory"), "Claude memory index")
    }

    private static let minimal = """
        {"id":9,"title":"t","why":"w","destination":"claude_skill_user","workbench_id":0,"prompt_id":"",\
        "kind":"add","metric":"corrections","before":"","after":"x","evidence":[],"sources":1,\
        "status":"open","created_at":"2026-11-01T09:00:00Z","decided_at":null,"baseline":null,\
        "verdict":"","verdict_value":null,"verdict_at":null,"reverts_id":0,"budget":0}
        """

    func testFailureParsePicksJSONLineBeforeProse() {
        let err = "junk\n{\"ok\":false,\"error\":\"busy\",\"code\":\"busy\"}\ncoach: the coach is already running\n"
        let f = CoachFailure.parse(stderr: err)
        XCTAssertEqual(f?.code, "busy")
        XCTAssertEqual(f?.error, "busy")
        XCTAssertNil(f?.diff)
    }

    func testFailureParseLastJSONWins() {
        let err = "{\"ok\":false,\"error\":\"a\"}\n{\"ok\":false,\"error\":\"b\",\"diff\":\"d\"}\n"
        XCTAssertEqual(CoachFailure.parse(stderr: err)?.error, "b")
        XCTAssertEqual(CoachFailure.parse(stderr: err)?.diff, "d")
    }

    func testFailureParseNoJSON() {
        XCTAssertNil(CoachFailure.parse(stderr: "just prose\nmore prose"))
        XCTAssertNil(CoachFailure.parse(stderr: "{\"x\":1}\n"))
        XCTAssertNil(CoachFailure.parse(stderr: ""))
    }
}

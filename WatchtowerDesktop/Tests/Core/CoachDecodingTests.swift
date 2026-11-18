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

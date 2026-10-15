import XCTest
@testable import WatchtowerCore

final class WorkbenchWorktreeDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testFullCreateEnvelope() throws {
        let r = try decode(WorktreeCreateResult.self, """
        {"workbench_id":7,"created":true,"path":"/repo/.claude/worktrees/a","cwd":"/repo/.claude/worktrees/a/sub",
         "branch":"wt/a","base":"abc123","base_branch":"main","base_dirty":true,"included":[".env"],
         "include_warnings":["w1"],"refused":"","refused_detail":"","error":"","warning":"late","integration_error":"ie"}
        """)
        XCTAssertEqual(r.workbenchID, 7)
        XCTAssertTrue(r.created)
        XCTAssertEqual(r.path, "/repo/.claude/worktrees/a")
        XCTAssertEqual(r.cwd, "/repo/.claude/worktrees/a/sub")
        XCTAssertEqual(r.branch, "wt/a")
        XCTAssertEqual(r.base, "abc123")
        XCTAssertEqual(r.baseBranch, "main")
        XCTAssertTrue(r.baseDirty)
        XCTAssertEqual(r.included, [".env"])
        XCTAssertEqual(r.includeWarnings, ["w1"])
        XCTAssertEqual(r.warning, "late")
        XCTAssertEqual(r.integrationError, "ie")
    }

    func testRefusedEnvelopeWithEmptyArrays() throws {
        let r = try decode(WorktreeCreateResult.self, """
        {"workbench_id":7,"created":false,"path":"","cwd":"","branch":"","base":"","base_branch":"","base_dirty":false,
         "included":[],"include_warnings":[],"refused":"unborn","refused_detail":"no commit","error":"","warning":""}
        """)
        XCTAssertFalse(r.created)
        XCTAssertEqual(r.refused, "unborn")
        XCTAssertEqual(r.refusedDetail, "no commit")
        XCTAssertEqual(r.included, [])
        XCTAssertEqual(r.integrationError, "", "a missing key defaults")
    }

    func testForgetEnvelope() throws {
        let ok = try decode(WorktreeForgetResult.self, #"{"workbench_id":3,"forgot":true,"error":""}"#)
        XCTAssertEqual(ok, try decode(WorktreeForgetResult.self, #"{"workbench_id":3,"forgot":true}"#))
        XCTAssertTrue(ok.forgot)
        let bad = try decode(WorktreeForgetResult.self, #"{"workbench_id":3,"forgot":false,"error":"refused: x"}"#)
        XCTAssertFalse(bad.forgot)
        XCTAssertEqual(bad.error, "refused: x")
    }
}

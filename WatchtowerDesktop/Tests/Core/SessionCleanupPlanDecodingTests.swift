import XCTest
import WatchtowerCore

/// `watchtower workbench cleanup --json` (Go's `sessioncleanup.Result`)
/// decodes into `SessionCleanupPlan`, tolerantly: nothing the CLI may add or
/// leave out fails the whole plan.
final class SessionCleanupPlanDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> SessionCleanupPlan {
        try JSONDecoder().decode(SessionCleanupPlan.self, from: Data(json.utf8))
    }

    func testDecodesTheCLIShape() throws {
        let plan = try decode("""
            {"session_id":12,"workbench_id":3,"mode":"plan","sweep":false,
             "items":[
              {"key":"wt:/tmp/acme/.claude/worktrees/a","kind":"worktree","name":"/tmp/acme/.claude/worktrees/a",
               "branch":"worktree-a","bytes":12000000000,"bytes_known":true,"action":"remove","reason":"",
               "detail":"","done":false,"error":""},
              {"key":"br:feature-x","kind":"branch","name":"feature-x","branch":"feature-x","bytes":0,
               "bytes_known":false,"action":"keep","reason":"unpushed_commits","detail":"3 commits",
               "done":false,"error":""}],
             "default_branch":"main","removed_bytes":0,"removed_bytes_known":true,
             "summary":"1 worktree to remove (~12 GB)","result_saved":false,"result_error":""}
            """)
        XCTAssertEqual(plan.sessionID, 12)
        XCTAssertEqual(plan.workbenchID, 3)
        XCTAssertEqual(plan.mode, "plan")
        XCTAssertEqual(plan.defaultBranch, "main")
        XCTAssertTrue(plan.removedBytesKnown)
        XCTAssertEqual(plan.summary, "1 worktree to remove (~12 GB)")
        XCTAssertEqual(plan.items.count, 2)
        let worktree = plan.items[0]
        XCTAssertEqual(worktree.kind, .worktree)
        XCTAssertEqual(worktree.action, .remove)
        XCTAssertNil(worktree.reason, "an empty reason is none")
        XCTAssertEqual(worktree.bytes, 12_000_000_000)
        XCTAssertTrue(worktree.bytesKnown)
        XCTAssertEqual(plan.items[1].reason, .known(.unpushedCommits))
        XCTAssertEqual(plan.items[1].detail, "3 commits")
        XCTAssertEqual(plan.removableKeys, ["wt:/tmp/acme/.claude/worktrees/a"])
    }

    func testEmptyAndMissingItemsAreAnEmptyList() throws {
        XCTAssertEqual(try decode(#"{"items":[]}"#).items, [])
        XCTAssertEqual(try decode(#"{"items":null}"#).items, [])
        let bare = try decode("{}")
        XCTAssertEqual(bare.items, [])
        XCTAssertFalse(bare.removedBytesKnown, "an absent measurement is not a known size")
        XCTAssertEqual(bare.summary, "")
    }

    func testUnknownKindActionAndReasonDecodeAsUnknown() throws {
        let plan = try decode("""
            {"items":[{"key":"k","kind":"volume","action":"archive","reason":"cosmic_rays"}]}
            """)
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.kind, .unknown("volume"))
        XCTAssertEqual(item.action, .unknown("archive"))
        XCTAssertEqual(item.reason, .unknown("cosmic_rays"))
        XCTAssertEqual(item.reason?.code, "cosmic_rays")
        XCTAssertFalse(item.isPendingRemoval)
    }

    func testMissingOwnerIsNilAndSweepOwnersDecode() throws {
        let plan = try decode("""
            {"sweep":true,"items":[
              {"key":"a","kind":"worktree","action":"keep"},
              {"key":"b","kind":"worktree","action":"keep","owner":{"unknown":true}},
              {"key":"c","kind":"branch","action":"keep","reason":"session_recent",
               "owner":{"session_id":7,"title":"Fix the login form","last_active":"2026-10-12T10:00:00Z"}}]}
            """)
        XCTAssertTrue(plan.sweep)
        XCTAssertNil(plan.items[0].owner)
        XCTAssertEqual(plan.items[1].owner, SessionCleanupOwner(isUnknown: true))
        XCTAssertEqual(plan.items[2].owner, SessionCleanupOwner(
            sessionID: 7, title: "Fix the login form", lastActive: "2026-10-12T10:00:00Z"
        ))
    }

    func testAnAppliedResultCountsOnlyWhatIsStillPending() throws {
        let plan = try decode("""
            {"mode":"apply","removed_bytes":500,"removed_bytes_known":false,"items":[
              {"key":"a","kind":"worktree","action":"remove","done":true},
              {"key":"b","kind":"branch","action":"remove","error":"boom"},
              {"key":"c","kind":"branch","action":"remove"}]}
            """)
        XCTAssertEqual(plan.removedBytes, 500)
        XCTAssertFalse(plan.removedBytesKnown)
        XCTAssertEqual(plan.removableKeys, ["c"])
    }

    func testEveryKnownReasonCodeRoundTrips() {
        for code in SessionCleanupReason.Code.allCases {
            XCTAssertEqual(SessionCleanupReason(code: code.rawValue), .known(code))
            XCTAssertEqual(SessionCleanupReason(code: code.rawValue).code, code.rawValue)
        }
    }
}

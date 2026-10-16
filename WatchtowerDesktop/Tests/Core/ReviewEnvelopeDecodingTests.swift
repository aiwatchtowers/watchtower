import XCTest
@testable import WatchtowerCore

/// Go-shaped `workbench review … --json` envelopes, including the `null`
/// slices Go emits for empty lists.
final class ReviewEnvelopeDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> ReviewEnvelope {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ReviewEnvelope.self, from: Data(json.utf8))
    }

    func testDiffWithNullHunks() throws {
        let env = try decode("""
            {"ok":true,"diff":{"files":[
            {"path":"big.txt","status":"added","additions":6000,"deletions":0,"binary":false,"collapsed_reason":"too_large",
             "new_blob":"b1","new_mode":"100644","hunks":null},
            {"path":"a.go","status":"modified","additions":1,"deletions":1,"binary":false,"new_blob":"b2","new_mode":"100755","hunks":[
            {"hunk_id":"h","header":"@@ -1 +1 @@","old_start":1,"old_lines":1,"new_start":1,"new_lines":1,"lines":["-a","+b"]}]}],
            "truncated":false},"from":"b","to":"t"}
            """)
        let files = try XCTUnwrap(env.diff?.files)
        XCTAssertEqual(files.map(\.hunks.count), [0, 1])
        XCTAssertEqual(files[0].collapsedReason, "too_large")
        XCTAssertEqual(files[1].hunks[0].lines, ["-a", "+b"])
        XCTAssertEqual(files[0].newBlob, "b1")
        XCTAssertEqual(files[1].newMode, "100755")
        XCTAssertEqual(env.from, "b")
    }

    func testDiffWithNullFiles() throws {
        let env = try decode(#"{"ok":true,"diff":{"files":null,"truncated":false},"from":"b","to":"t"}"#)
        XCTAssertEqual(env.diff?.files.count, 0)
    }

    func testNullHunkLines() throws {
        let env = try decode("""
            {"ok":true,"diff":{"files":[{"path":"a","status":"modified","additions":0,"deletions":0,"binary":false,
            "new_blob":"","new_mode":"","hunks":[
            {"hunk_id":"h","header":"@@","old_start":1,"old_lines":0,"new_start":1,"new_lines":0,"lines":null}]}],"truncated":false}}
            """)
        XCTAssertEqual(env.diff?.files.first?.hunks.first?.lines, [])
    }

    func testContextMissingIsAString() throws {
        let env = try decode("""
            {"ok":true,"items":[
            {"target_id":1,"text":"t","intent":"i","missing":"plan"},
            {"target_id":2,"text":"t","intent":"i","plan_path":"p.md","plan_task":3}]}
            """)
        let items = try XCTUnwrap(env.items)
        XCTAssertEqual(items[0].missing, "plan")
        XCTAssertNil(items[1].missing)
        XCTAssertEqual(items[1].planTask, 3)
    }

    func testStartAndSendEnvelopes() throws {
        let start = try decode("""
            {"ok":true,"round":{"id":7,"status":"open","mode":"quick","folder_root":"/tmp/acme","base_sha":"b","base_label":"main",
            "tree_sha":"t","prev_round_id":6,"prev_tree_sha":"p","prev_tree_lost":true}}
            """)
        XCTAssertEqual(start.round?.id, 7)
        XCTAssertEqual(start.round?.prevTreeLost, true)
        let send = try decode(#"{"ok":true,"sent":false}"#)
        XCTAssertEqual(send.sent, false)
        XCTAssertNil(send.comments)
        XCTAssertNil(send.line)
    }
}

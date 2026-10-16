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

    func testLensesAndRoundDeepFieldsDecode() throws {
        let env = try decode("""
            {"ok":true,"round":{"id":7,"status":"open","mode":"deep","folder_root":"/tmp/acme","base_sha":"b","base_label":"main",
            "tree_sha":"t","prev_round_id":0,"prev_tree_sha":"","prev_tree_lost":false,
            "phase":"chapters","chapter_key":"dir:cmd","active_seconds":42},
            "lenses":[{"id":"tests","name":"Tests","builtin":true,"items":[{"key":"0123456789abcdef","text":"Covered?"}]}],
            "lens_notes":["line 3: skipped"]}
            """)
        XCTAssertEqual(env.round?.phase, "chapters")
        XCTAssertEqual(env.round?.chapterKey, "dir:cmd")
        XCTAssertEqual(env.round?.activeSeconds, 42)
        XCTAssertEqual(env.lenses?.first?.id, "tests")
        XCTAssertEqual(env.lenses?.first?.builtin, true)
        XCTAssertEqual(env.lenses?.first?.items, [.init(key: "0123456789abcdef", text: "Covered?")])
        XCTAssertEqual(env.lensNotes, ["line 3: skipped"])
    }

    func testRoundWithoutDeepKeysDefaults() throws {
        let env = try decode("""
            {"ok":true,"round":{"id":7,"status":"open","mode":"quick","folder_root":"/tmp/acme","base_sha":"b","base_label":"main",
            "tree_sha":"t","prev_round_id":0,"prev_tree_sha":"","prev_tree_lost":false}}
            """)
        XCTAssertEqual(env.round?.phase, "")
        XCTAssertEqual(env.round?.chapterKey, "")
        XCTAssertEqual(env.round?.activeSeconds, 0)
        XCTAssertNil(env.lenses)
        XCTAssertNil(env.lensNotes)
    }

    func testReviewPhaseStoredDefaultsToMeaning() {
        XCTAssertEqual(ReviewPhase(stored: ""), .meaning)
        XCTAssertEqual(ReviewPhase(stored: "x"), .meaning)
        XCTAssertEqual(ReviewPhase(stored: "wrapup"), .wrapup)
        XCTAssertEqual(ReviewPhase(stored: "chapters"), .chapters)
    }

    func testOverviewDecodesTheGoFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/reviewai/testdata/overview_ok.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let ov = try decoder.decode(ReviewOverview.self, from: Data(contentsOf: url))
        XCTAssertEqual(ov.summary, "Adds the greeting endpoint and its test; the docs update is missing.")
        XCTAssertEqual(ov.coverage, [
            .init(item: "Add a greeting endpoint", status: .done, where: ["server/greet.go"]),
            .init(item: "Document the endpoint", status: .notFound, where: [])
        ])
        XCTAssertEqual(ov.outOfScope, ["scripts/cleanup.sh"])
        XCTAssertEqual(ov.risk, [
            .init(path: "server/greet.go", level: .medium, why: "new public handler"),
            .init(path: "server/greet_test.go", level: .low, why: "test only"),
            .init(path: "scripts/cleanup.sh", level: .high, why: "deletes files")
        ])
        XCTAssertEqual(ov.chapters, [
            .init(title: "Greeting endpoint", paths: ["server/greet.go", "server/greet_test.go"], core: true, lenses: ["correctness", "tests"]),
            .init(title: "Housekeeping", paths: ["scripts/cleanup.sh"], core: false, lenses: [])
        ])
    }

    func testOverviewMissingArraysAreEmpty() throws {
        let env = try decode("""
            {"ok":true,"overview":{"summary":"s","coverage":null,"chapters":[{"title":"t","paths":null}]},"overview_cached":true}
            """)
        let ov = try XCTUnwrap(env.overview)
        XCTAssertEqual(ov.coverage, [])
        XCTAssertEqual(ov.outOfScope, [])
        XCTAssertEqual(ov.risk, [])
        XCTAssertEqual(ov.chapters.first?.paths, [])
        XCTAssertEqual(env.overviewCached, true)
    }

    func testRevertLessonsAndWrittenEnvelopes() throws {
        let revert = try decode(#"{"ok":true,"revert":{"hunk_id":"0123456789abcdef","path":"a.go"}}"#)
        XCTAssertEqual(revert.revert?.hunkId, "0123456789abcdef")
        XCTAssertEqual(revert.revert?.path, "a.go")
        XCTAssertNil(revert.lessons)
        let propose = try decode(#"{"ok":true,"lessons":[]}"#)
        XCTAssertEqual(propose.lessons, [])
        let withLessons = try decode("""
            {"ok":true,"lessons":[{"id":3,"lens":"tests","text":"add tests","source_comment_ids":[4,7],"status":"proposed"}]}
            """)
        XCTAssertEqual(withLessons.lessons, [ReviewLesson(id: 3, lens: "tests", text: "add tests", sourceCommentIDs: [4, 7], status: "proposed")])
        let accept = try decode(#"{"ok":true,"written":".watchtower/review.md"}"#)
        XCTAssertEqual(accept.written, ".watchtower/review.md")
        XCTAssertNil(accept.lessons)
    }
}

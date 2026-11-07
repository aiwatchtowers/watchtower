import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// Board #1012: a round that moved to the session's new place, and a round
/// on the task branch's tip. Split out of ReviewChangesModelTests to keep
/// that file under the length cap.
extension ReviewChangesModelTests {
    /// Board #1012: Go moves an open round to the session's new place on a
    /// plain start; reopening the pane re-places its drafts on the new tree.
    func testOpenOfAMovedRoundReplacesItsDrafts() async throws {
        let h = try harness()
        h.baseScript()
        h.cli.script("start", [startJSON(id: 7, prev: 0), startJSON(id: 7, prev: 0, tree: "u")])
        h.cli.script("file", [fileJSON(old: "x\n", new: "keep\ngone\n"), fileJSON(old: "x\n", new: "added\nkeep\n")])
        await h.model.open()
        await h.model.select("a.go")
        try await h.model.addComment(path: "a.go", side: "new", startLine: 1, endLine: 1, body: "moves")
        try await h.model.addComment(path: "a.go", side: "new", startLine: 2, endLine: 2, body: "lost")
        await h.model.open()
        let rows = try await h.comments()
        XCTAssertEqual(rows.first { $0.body == "moves" }?.startLine, 2)
        XCTAssertEqual(rows.first { $0.body == "moves" }?.treeSHA, "u7")
        XCTAssertEqual(rows.first { $0.body == "lost" }?.status, .outdated)
        XCTAssertEqual(h.model.comments, rows)
    }

    /// Board #1012: a round on the task branch's tip reads commits, not a
    /// folder — Undo is off and never reaches the CLI.
    func testUndoRefusedOnABranchTipRoundCallsNoCLI() async throws {
        let h = try harness()
        h.baseScript()
        h.cli.script(["start": """
            {"ok":true,"round":{"id":7,"status":"open","mode":"quick","source":"pr","branch":"feature/x","folder_root":"/r",
             "base_sha":"b","base_label":"main","tree_sha":"t7","prev_round_id":0,"prev_tree_sha":"","prev_tree_lost":false}}
            """])
        h.cli.script(["revert-hunk": #"{"ok":true,"revert":{"hunk_id":"0123456789abcdef","path":"a.go"}}"#])
        await h.model.open()
        XCTAssertEqual(h.model.round?.isBranchTip, true)
        XCTAssertFalse(h.model.canUndo)
        await h.model.undo(hunkID: "0123456789abcdef")
        XCTAssertEqual(h.model.lastError, ReviewChangesModel.branchTipUndoMessage)
        XCTAssertEqual(h.cli.calls("revert-hunk"), [])
    }
}

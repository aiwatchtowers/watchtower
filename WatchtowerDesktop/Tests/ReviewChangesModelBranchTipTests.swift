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

    /// A round answer on base `base` and tree `tree` (id 7).
    private func roundJSON(base: String, tree: String, mode: String = "quick", placeMissing: Bool = false) -> String {
        """
        {"ok":true,"round":{"id":7,"status":"open","mode":"\(mode)","folder_root":"/r","base_sha":"\(base)",
         "base_label":"main","tree_sha":"\(tree)","prev_round_id":0,"prev_tree_sha":"","prev_tree_lost":false}\(
             placeMissing ? #","place_missing":true"# : "")}
        """
    }

    /// A move that changes only the base (a folder round on the task branch
    /// measured against its parent branch, then on the default branch) makes
    /// the overview stale (board #1012, m1).
    func testBaseOnlyChangeRegeneratesTheOverview() async throws {
        let h = try harness()
        h.cli.script(["context": deepContextJSON(), "diff": diffJSON(["a.go"])])
        h.cli.script("start", [roundJSON(base: "b", tree: "t7", mode: "deep"), roundJSON(base: "c", tree: "t7", mode: "deep")])
        h.cli.script("overview", [
            #"{"ok":true,"overview":{"summary":"On b."},"overview_cached":false}"#,
            #"{"ok":true,"overview":{"summary":"On c."},"overview_cached":false}"#
        ])
        await h.model.open()
        await awaitOverview(h)
        XCTAssertEqual(h.cli.calls("overview").count, 1)
        await h.model.refresh()
        await awaitOverview(h)
        XCTAssertEqual(h.cli.calls("overview").count, 2, "the same tree on another base is another diff")
        guard case .ready(let after) = h.model.overview else { return XCTFail("overview \(h.model.overview)") }
        XCTAssertEqual(after.summary, "On c.")
    }

    /// An old-side draft is anchored on the base: a base-only change re-places
    /// it although its tree is the round's (m1).
    func testBaseOnlyChangeReplacesOldSideDrafts() async throws {
        let h = try harness()
        h.cli.script(["context": #"{"ok":true,"items":[]}"#, "diff": diffJSON(["a.go"])])
        h.cli.script("start", [roundJSON(base: "b", tree: "t7"), roundJSON(base: "c", tree: "t7")])
        h.cli.script("file", [fileJSON(old: "x\ny\n", new: "n\n"), fileJSON(old: "y\n", new: "n\n")])
        await h.model.open()
        await h.model.select("a.go")
        try await h.model.addComment(path: "a.go", side: "old", startLine: 2, endLine: 2, body: "on y")
        await h.model.refresh()
        let row = try await h.comments().first { $0.body == "on y" }
        XCTAssertEqual(row?.startLine, 1, "re-placed on the new base's old side")
        XCTAssertEqual(row?.status, .draft)
    }

    /// S5: a moved round whose comments cannot be re-placed still opens; the
    /// failure is the pane's banner and the rows stay as they were.
    func testOpenFinishesWhenCommentsCannotBeReplaced() async throws {
        let h = try harness()
        h.baseScript()
        h.cli.script("start", [startJSON(id: 7, prev: 0), startJSON(id: 7, prev: 0, tree: "u")])
        h.cli.script("file", [fileJSON(old: "x\n", new: "keep\n"), #"{"ok":false,"error":"boom"}"#, fileJSON(old: "x\n", new: "keep\n")])
        await h.model.open()
        await h.model.select("a.go")
        try await h.model.addComment(path: "a.go", side: "new", startLine: 1, endLine: 1, body: "stays")
        await h.model.open()
        XCTAssertEqual(h.model.load, .ready)
        XCTAssertEqual(h.model.round?.treeSha, "u7")
        XCTAssertEqual(h.model.lastError, "Could not re-place 1 comment on the new tree: boom")
        let row = try await h.comments().first { $0.body == "stays" }
        XCTAssertEqual(row?.treeSHA, "t7", "untouched")
        XCTAssertEqual(row?.status, .draft)
    }

    /// M2: Go keeps an open round in place when the session's worktree was
    /// removed and says so; the pane shows the notice until the place is back.
    func testRemovedWorktreeNotice() async throws {
        let h = try harness()
        h.cli.script(["context": #"{"ok":true,"items":[]}"#, "diff": diffJSON(["a.go"])])
        h.cli.script("start", [roundJSON(base: "b", tree: "t7", placeMissing: true), roundJSON(base: "b", tree: "t7")])
        await h.model.open()
        XCTAssertTrue(h.model.placeMissing)
        await h.model.refresh()
        XCTAssertFalse(h.model.placeMissing)
    }
}

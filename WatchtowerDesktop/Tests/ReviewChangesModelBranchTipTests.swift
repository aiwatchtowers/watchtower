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

    /// Codex verify: a Refresh that finds the round moved (no previous round
    /// any more) leaves the Since view, whose picker is gone, for All changes.
    func testRefreshOfAMovedRoundFallsBackToAllChanges() async throws {
        let h = try harness()
        let r6 = try await h.db.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO review_rounds (project_id, session_id, folder_root, base_sha, tree_sha, status)
                VALUES (?, ?, '/r', 'b', 't6', 'sent')
                """, arguments: [h.projectID, h.sessionID])
            return db.lastInsertedRowID
        }
        h.baseScript(id: 7, prev: r6)
        h.cli.script("start", [startJSON(id: 7, prev: r6), startJSON(id: 7, prev: 0, tree: "u")])
        await h.model.open()
        XCTAssertEqual(h.model.view, .sinceLastRound)
        await h.model.refresh()
        XCTAssertEqual(h.model.view, .all)
        XCTAssertEqual(h.cli.calls("diff").last?.contains("--since"), false, "the moved round's diff is read whole")
    }

    /// Codex verify: a base-only re-placement that fails is retried by the
    /// next Refresh, which re-anchors the old-side draft.
    func testFailedBaseReplacementIsRetriedByTheNextRefresh() async throws {
        let h = try harness()
        h.cli.script(["context": #"{"ok":true,"items":[]}"#, "diff": diffJSON(["a.go"])])
        h.cli.script("start", [roundJSON(base: "b", tree: "t7"), roundJSON(base: "c", tree: "t7")])
        h.cli.script("file", [fileJSON(old: "x\ny\n", new: "n\n"), #"{"ok":false,"error":"boom"}"#, fileJSON(old: "y\n", new: "n\n")])
        await h.model.open()
        await h.model.select("a.go")
        try await h.model.addComment(path: "a.go", side: "old", startLine: 2, endLine: 2, body: "on y")
        await h.model.refresh()
        XCTAssertEqual(h.model.lastError, "boom")
        let before = try await h.comments().first { $0.body == "on y" }
        XCTAssertEqual(before?.startLine, 2, "not placed yet")
        await h.model.refresh()
        XCTAssertNil(h.model.lastError)
        let after = try await h.comments().first { $0.body == "on y" }
        XCTAssertEqual(after?.startLine, 1, "re-placed on the retry")
    }

    /// REVIEW-03 across a place change (board #1012): the round after a sent
    /// round of another place carries its unresolved comments, and since Go
    /// answers that round's tree as lost, the pane opens on All changes.
    func testRoundAtAnotherPlaceCarriesCommentsAndShowsAllChanges() async throws {
        let h = try harness()
        let r6 = try await h.db.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO review_rounds (project_id, session_id, folder_root, base_sha, tree_sha, status)
                VALUES (?, ?, '/r', 'b', 't6', 'sent')
                """, arguments: [h.projectID, h.sessionID])
            return db.lastInsertedRowID
        }
        let anchor = ReviewCommentAnchor.anchor(text: "old line\n", startLine: 1, endLine: 1)
        try await h.db.write { db in
            let id = try ReviewQueries.addDraft(db, roundID: r6, path: "a.go", side: "new", startLine: 1, endLine: 1,
                                                anchor: anchor, treeSHA: "t6", body: "fix this")
            try db.execute(sql: "UPDATE review_comments SET status='sent' WHERE id=?", arguments: [id])
        }
        h.baseScript(id: 7, prev: r6)
        h.cli.script(["start": """
            {"ok":true,"round":{"id":7,"status":"open","mode":"quick","source":"pr","branch":"feature/x","folder_root":"/r",
             "base_sha":"b","base_label":"main","tree_sha":"t7","prev_round_id":\(r6),"prev_tree_sha":"t6","prev_tree_lost":true}}
            """, "file": fileJSON(old: "old line\n", new: "inserted\nold line\n")])
        await h.model.open()
        let carried = try await h.comments()
        XCTAssertEqual(carried.map(\.status), [.carried])
        XCTAssertEqual(carried.first?.body, "fix this")
        XCTAssertEqual(h.model.view, .all)
        XCTAssertTrue(h.model.previousTreeLost)
        XCTAssertFalse(h.cli.calls("diff").contains { $0.contains("--since") })
    }

    /// Codex round 3: a draft on a blank line has no quote to find; a plain
    /// reopen (which re-places old-side drafts) leaves it as it is.
    func testReopenLeavesADraftOnABlankLine() async throws {
        let h = try harness()
        h.baseScript()
        h.cli.script(["file": fileJSON(old: "x\n\ny\n", new: "n\n")])
        await h.model.open()
        await h.model.select("a.go")
        try await h.model.addComment(path: "a.go", side: "old", startLine: 2, endLine: 2, body: "blank")
        // A fresh pane on the same round: it has not placed the comments yet.
        let cli = ReviewScriptedRunner(db: h.db, projectID: h.projectID, sessionID: h.sessionID)
        cli.script(["start": startJSON(id: 7, prev: 0), "context": #"{"ok":true,"items":[]}"#, "diff": diffJSON(["a.go"]),
                    "file": fileJSON(old: "x\n\ny\n", new: "n\n")])
        let fresh = ReviewChangesModel(projectID: h.projectID, sessionID: h.sessionID, cli: WorkbenchCLI(runner: cli), db: h.db,
                                       lineDelivery: h.sink) { false }
        await fresh.open()
        XCTAssertEqual(fresh.load, .ready)
        let row = try await h.comments().first { $0.body == "blank" }
        XCTAssertEqual(row?.status, .draft)
        XCTAssertEqual(row?.startLine, 2)
    }
}

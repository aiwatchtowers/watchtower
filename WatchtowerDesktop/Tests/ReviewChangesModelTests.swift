import GRDB
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Answers `workbench review <sub> …` from a script keyed by the subcommand
/// (`args[2]`): one answer per call, the last repeating. A served `start`
/// makes the round row exist, and a served `send` that sent closes the round
/// and its drafts, as Go's do.
private final class ScriptedRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [String: [String]] = [:]
    private var served: [String: Int] = [:]
    private var seen: [[String]] = []
    /// The round's `active_seconds` as the DB held it when a `send` was served.
    private(set) var activeSecondsAtSend: Int?
    private let db: DatabasePool
    private let projectID: Int64
    private let sessionID: Int64

    init(db: DatabasePool, projectID: Int64, sessionID: Int64) {
        self.db = db
        self.projectID = projectID
        self.sessionID = sessionID
    }

    func script(_ answers: [String: String]) { lock.withLock { for (k, v) in answers { script[k] = [v] } } }
    func script(_ sub: String, _ answers: [String]) { lock.withLock { script[sub] = answers } }
    var calls: [[String]] { lock.withLock { seen } }
    func calls(_ sub: String) -> [[String]] { calls.filter { $0.count > 2 && $0[2] == sub } }

    // Held subcommands: a call waits (its answer already picked) until `release`.
    private var holding: Set<String> = []
    private var held: [String: [CheckedContinuation<Void, Never>]] = [:]
    func hold(_ sub: String) { lock.withLock { _ = holding.insert(sub) } }
    func pending(_ sub: String) -> Int { lock.withLock { held[sub]?.count ?? 0 } }
    func release(_ sub: String) {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holding.remove(sub)
            defer { held[sub] = nil }
            return held[sub] ?? []
        }
        waiting.forEach { $0.resume() }
    }

    /// Waits (bounded) until `count` calls of `sub` are held.
    func waitPending(_ sub: String, count: Int = 1) async {
        for _ in 0..<2000 where pending(sub) < count {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func run(args: [String]) async throws -> Data {
        let sub = args[2]
        let answer: String = lock.withLock {
            seen.append(args)
            let key = sub == "diff" && args.contains("--since") && script["diff-since"] != nil ? "diff-since" : sub
            let list = script[key] ?? [#"{"ok":false,"error":"unscripted \#(sub)"}"#]
            let n = served[key, default: 0]
            served[key] = n + 1
            return list[min(n, list.count - 1)]
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let wait = lock.withLock { () -> Bool in
                guard holding.contains(sub) else { return false }
                held[sub, default: []].append(c)
                return true
            }
            if !wait { c.resume() }
        }
        if sub == "start" { try seedRound(answer) }
        if sub == "send", let i = args.firstIndex(of: "--round"), let id = Int64(args[i + 1]) {
            let seen = try await db.read { try Int.fetchOne($0, sql: "SELECT active_seconds FROM review_rounds WHERE id = ?", arguments: [id]) }
            lock.withLock { activeSecondsAtSend = seen }
        }
        if sub == "send", answer.contains(#""sent":true"#), let i = args.firstIndex(of: "--round"), let id = Int64(args[i + 1]) {
            try markSent(id)
        }
        return Data(answer.utf8)
    }

    private func markSent(_ id: Int64) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE review_rounds SET status = 'sent' WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE review_comments SET status = 'sent' WHERE round_id = ? AND status IN ('draft','carried')",
                           arguments: [id])
        }
    }

    private func seedRound(_ json: String) throws {
        guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let round = obj["round"] as? [String: Any], let id = round["id"] as? Int64 ?? (round["id"] as? Int).map(Int64.init),
              let tree = round["tree_sha"] as? String else { return }
        let prev = (round["prev_round_id"] as? Int).map(Int64.init) ?? 0
        let (project, session) = (projectID, sessionID)
        try db.write { db in
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM review_rounds WHERE id = ?)", arguments: [id]) == true {
                try db.execute(sql: "UPDATE review_rounds SET tree_sha = ? WHERE id = ?", arguments: [tree, id])
            } else {
                try db.execute(sql: """
                    INSERT INTO review_rounds (id, project_id, session_id, folder_root, base_sha, tree_sha, prev_round_id)
                    VALUES (?, ?, ?, '/r', 'b', ?, ?)
                    """, arguments: [id, project, session, tree, prev > 0 ? prev : nil])
            }
        }
    }
}

@MainActor
private final class RecordingSink: ReviewLineSink {
    struct Line: Equatable {
        let text: String
        let key: SessionLineDelivery.LineKey
        let sessionID: Int64
    }

    var lines: [Line] = []
    var result: SessionLineDelivery.Delivery = .submitted

    func deliverLine(_ line: String, key: SessionLineDelivery.LineKey, sessionID: Int64) async -> SessionLineDelivery.Delivery {
        lines.append(Line(text: line, key: key, sessionID: sessionID))
        return result
    }
}

@MainActor
private struct Harness {
    let db: DatabasePool
    let path: String
    let projectID: Int64
    let sessionID: Int64
    let cli: ScriptedRunner
    let sink = RecordingSink()
    let model: ReviewChangesModel

    init() throws {
        let (pool, path) = try TestDatabase.createPool()
        let ids = try pool.write { db -> (Int64, Int64) in
            let project = try TestDatabase.insertWorkbench(db, name: "acme", folder: "/tmp/acme")
            try db.execute(sql: "INSERT INTO terminal_sessions (project_id, kind, title, folder_path) VALUES (?, 'shell', 'S', '/tmp/acme')",
                           arguments: [project])
            return (project, db.lastInsertedRowID)
        }
        db = pool
        self.path = path
        projectID = ids.0
        sessionID = ids.1
        cli = ScriptedRunner(db: pool, projectID: ids.0, sessionID: ids.1)
        model = ReviewChangesModel(projectID: ids.0, sessionID: ids.1, cli: WorkbenchCLI(runner: cli), db: pool, lineDelivery: sink)
    }

    func baseScript(id: Int64 = 7, prev: Int64 = 0, paths: [String] = ["a.go"]) {
        cli.script(["start": startJSON(id: id, prev: prev), "context": #"{"ok":true,"items":[]}"#, "diff": diffJSON(paths)])
    }

    func comments(_ round: Int64 = 7) async throws -> [ReviewComment] {
        try await db.read { try ReviewQueries.comments($0, roundID: round) }
    }
}

private func startJSON(id: Int64, prev: Int64, tree: String = "t") -> String {
    """
    {"ok":true,"round":{"id":\(id),"status":"open","mode":"quick","folder_root":"/r","base_sha":"b","base_label":"main",
     "tree_sha":"\(tree)\(id)","prev_round_id":\(prev),"prev_tree_sha":"","prev_tree_lost":false}}
    """
}

/// One modified file per path; its new blob follows the hunk name, so a
/// changed `hunk` is changed content.
private func diffJSON(_ paths: [String], hunk: String = "h") -> String {
    let hunkFields = #""header":"@@ -1 +1 @@","old_start":1,"old_lines":1,"new_start":1,"new_lines":1,"lines":["-a","+b"]"#
    let entries: [String] = paths.map { path in
        """
        {"path":"\(path)","status":"modified","additions":1,"deletions":1,"binary":false,
         "new_blob":"\(hunk)-\(path)","new_mode":"100644","hunks":[{"hunk_id":"\(hunk)-\(path)",\(hunkFields)}]}
        """
    }
    let files = entries.joined(separator: ",")
    return #"{"ok":true,"diff":{"files":[\#(files)],"truncated":false},"from":"b","to":"t"}"#
}

private func diffJSON(path: String) -> String { diffJSON([path]) }

private func fileJSON(old: String, new: String) -> String {
    func side(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\n", with: "\\n")
        return #"{"exists":true,"text":"\#(escaped)","binary":false,"too_large":false}"#
    }
    return #"{"ok":true,"old":\#(side(old)),"new":\#(side(new))}"#
}

@MainActor
final class ReviewChangesModelTests: XCTestCase {
    private var paths: [String] = []
    private static let sentRoundSQL = """
        INSERT INTO review_rounds (project_id, session_id, folder_root, base_sha, tree_sha, status)
        VALUES (?, ?, '/r', 'b', 't6', 'sent')
        """

    override func tearDown() {
        paths.forEach { TestDatabase.cleanup(path: $0) }
        paths = []
        super.tearDown()
    }

    private func harness() throws -> Harness {
        let h = try Harness()
        paths.append(h.path)
        return h
    }

    func testOpenLoadsRoundDiffAndContext() async throws {
        let h = try harness()
        h.cli.script(["start": startJSON(id: 7, prev: 0), "context": #"{"ok":true,"items":[]}"#, "diff": diffJSON(path: "a.go")])
        await h.model.open()
        XCTAssertEqual(h.model.load, .ready)
        XCTAssertEqual(h.model.round?.id, 7)
        XCTAssertEqual(h.model.files.map(\.path), ["a.go"])
        XCTAssertEqual(h.model.view, .all)
    }

    func testFailedStartShowsTheError() async throws {
        let h = try harness()
        h.cli.script(["start": #"{"ok":false,"error":"the folder is not a git work tree"}"#])
        await h.model.open()
        XCTAssertEqual(h.model.load, .failed("the folder is not a git work tree"))
    }

    func testFailedDiffFailsTheOpen() async throws {
        let h = try harness()
        h.cli.script(["start": startJSON(id: 7, prev: 0), "context": #"{"ok":true,"items":[]}"#,
                      "diff": #"{"ok":false,"error":"git diff failed"}"#])
        await h.model.open()
        XCTAssertEqual(h.model.load, .failed("git diff failed"))
    }

    func testReview04_SendTypesOnce() async throws {
        let h = try harness()
        h.baseScript()
        h.cli.script(["send": #"{"ok":true,"sent":true,"comments":1,"line":"Review round #7 sent (1 comment)."}"#])
        await h.model.open()
        await h.model.select("a.go")
        // No file text is scripted: the sides fail to load, so anchor through the DB instead.
        try await h.db.write { db in
            _ = try ReviewQueries.addDraft(db, roundID: 7, path: "a.go", side: "new", startLine: 1, endLine: 1,
                                           anchor: CommentAnchor(quote: "x", prefix: "", suffix: "", heading: ""), treeSHA: "t7", body: "x")
        }
        async let a: Void = h.model.send()
        async let b: Void = h.model.send()
        _ = await (a, b)
        XCTAssertEqual(h.sink.lines.count, 1)
        XCTAssertEqual(h.sink.lines.first?.key, .review(7))
        XCTAssertEqual(h.sink.lines.first?.sessionID, h.sessionID)
        XCTAssertEqual(h.cli.calls("send").count, 1)
        XCTAssertEqual(h.model.lastSend, .submitted)
        XCTAssertFalse(h.model.sending)
    }

    func testAlreadySentTypesNothing() async throws {
        let h = try harness()
        h.baseScript()
        h.cli.script(["send": #"{"ok":true,"sent":false}"#])
        await h.model.open()
        await h.model.send()
        XCTAssertTrue(h.sink.lines.isEmpty)
        XCTAssertNil(h.model.lastSend)
        XCTAssertEqual(h.model.lastError, ReviewChangesModel.alreadySentMessage)
        XCTAssertEqual(h.model.round?.status, "sent", "a round Go calls sent is not open here either")
    }

    /// REVIEW-03 across a Send: the sent round takes no new comment, and the
    /// next Refresh opens the next round (never a refresh of the sent one),
    /// carrying the unresolved comments and the Viewed marks.
    func testSendThenRefreshOpensTheNextRoundAndCarries() async throws {
        let h = try harness()
        h.baseScript()
        h.cli.script("start", [startJSON(id: 7, prev: 0), startJSON(id: 8, prev: 7)])
        h.cli.script(["file": fileJSON(old: "x\n", new: "one\ntwo\n"),
                      "send": #"{"ok":true,"sent":true,"comments":1,"line":"Review round #7 sent (1 comment)."}"#])
        await h.model.open()
        await h.model.select("a.go")
        try h.model.addComment(path: "a.go", side: "new", startLine: 2, endLine: 2, body: "why two?")
        try h.model.toggleViewed("a.go")
        await h.model.send()
        XCTAssertEqual(h.model.round?.status, "sent")

        XCTAssertThrowsError(try h.model.addComment(path: "a.go", side: "new", startLine: 1, endLine: 1, body: "late")) {
            XCTAssertEqual($0 as? ReviewChangesModel.ModelError, .roundNotOpen)
        }
        XCTAssertNotNil(h.model.lastError)
        let sentRows = try await h.comments(7)
        XCTAssertEqual(sentRows.map(\.body), ["why two?"], "nothing written into the sent round")
        XCTAssertThrowsError(try h.model.editComment(id: try XCTUnwrap(sentRows.first).id, body: "edited")) {
            XCTAssertEqual($0 as? ReviewChangesModel.ModelError, .roundNotOpen)
        }

        await h.model.refresh()
        XCTAssertEqual(h.cli.calls("start").map { $0.contains("--refresh") }, [false, false], "the next round, not a refresh")
        XCTAssertEqual(h.model.round?.id, 8)
        XCTAssertEqual(h.model.round?.status, "open")
        let carried = try await h.comments(8)
        XCTAssertEqual(carried.map(\.status), [.carried])
        XCTAssertEqual(carried.first?.carriedFrom, sentRows.first?.id)
        XCTAssertEqual(carried.first?.startLine, 2)
        XCTAssertTrue(h.model.isViewed("a.go"), "an unchanged file keeps its Viewed mark")
        try h.model.addComment(path: "a.go", side: "new", startLine: 1, endLine: 1, body: "next round")
        let next = try await h.comments(8)
        XCTAssertEqual(next.count, 2)
    }

    /// The Viewed key follows the file's new blob and mode: a binary file
    /// (no hunks) changed again loses its mark, an unchanged one keeps it.
    func testViewedKeyFollowsTheBlobForBinaryFiles() async throws {
        func binary(_ blobs: [String: String]) -> String {
            let entries = blobs.keys.sorted().map { path in
                """
                {"path":"\(path)","status":"modified","additions":0,"deletions":0,"binary":true,
                 "new_blob":"\(blobs[path] ?? "")","new_mode":"100644","hunks":null}
                """
            }
            return #"{"ok":true,"diff":{"files":[\#(entries.joined(separator: ","))],"truncated":false},"from":"b","to":"t"}"#
        }
        let h = try harness()
        h.baseScript()
        h.cli.script("start", [startJSON(id: 7, prev: 0), startJSON(id: 7, prev: 0, tree: "u")])
        h.cli.script("diff", [binary(["img.png": "b1", "logo.png": "c1"]), binary(["img.png": "b2", "logo.png": "c1"])])
        await h.model.open()
        try h.model.toggleViewed("img.png")
        try h.model.toggleViewed("logo.png")
        await h.model.refresh()
        XCTAssertFalse(h.model.isViewed("img.png"))
        XCTAssertTrue(h.model.isViewed("logo.png"))
    }

    /// A renamed file's old side is read at its old path.
    func testRenamedFileReadsItsOldSideAtTheOldPath() async throws {
        let h = try harness()
        h.baseScript()
        let renamed = """
            {"ok":true,"diff":{"files":[{"path":"new.go","old_path":"old.go","status":"renamed","additions":0,"deletions":0,
             "binary":false,"new_blob":"n","new_mode":"100644","hunks":null}],"truncated":false},"from":"b","to":"t"}
            """
        h.cli.script(["diff": renamed, "file": fileJSON(old: "x\n", new: "x\n")])
        await h.model.open()
        await h.model.select("new.go")
        let args = try XCTUnwrap(h.cli.calls("file").last)
        let i = try XCTUnwrap(args.firstIndex(of: "--old-path"))
        XCTAssertEqual(args[i + 1], "old.go")
        XCTAssertEqual(h.model.currentSides?.old.text, "x\n")
    }

    func testRefusedSendSetsLastError() async throws {
        let h = try harness()
        h.baseScript()
        h.cli.script(["send": #"{"ok":false,"error":"nothing to send"}"#])
        await h.model.open()
        await h.model.send()
        XCTAssertTrue(h.sink.lines.isEmpty)
        XCTAssertEqual(h.model.lastError, "nothing to send")
    }

    func testNewRoundCarriesPreviousComments() async throws {
        let h = try harness()
        let r6 = try await h.db.write { db -> Int64 in
            try db.execute(sql: Self.sentRoundSQL, arguments: [h.projectID, h.sessionID])
            return db.lastInsertedRowID
        }
        let anchor = ReviewCommentAnchor.anchor(text: "old line\n", startLine: 1, endLine: 1)
        let c6 = try await h.db.write { db -> Int64 in
            let id = try ReviewQueries.addDraft(db, roundID: r6, path: "a.go", side: "new", startLine: 1, endLine: 1,
                                                anchor: anchor, treeSHA: "t6", body: "fix this")
            try db.execute(sql: "UPDATE review_comments SET status='sent' WHERE id=?", arguments: [id])
            return id
        }
        h.cli.script(["start": startJSON(id: 7, prev: r6), "context": #"{"ok":true,"items":[]}"#, "diff": diffJSON(path: "a.go"),
                      "file": fileJSON(old: "old line\n", new: "inserted\nold line\n")])
        await h.model.open()
        let carried = try await h.comments()
        XCTAssertEqual(carried.count, 1)
        XCTAssertEqual(carried.first?.status, .carried)
        XCTAssertEqual(carried.first?.startLine, 2)
        XCTAssertEqual(carried.first?.carriedFrom, c6)
        XCTAssertEqual(h.model.comments, carried)
        XCTAssertEqual(h.model.view, .sinceLastRound)
        XCTAssertTrue(h.cli.calls("diff").last?.contains("--since") == true)
    }

    func testNewRoundKeepsViewedMarksWhoseContentIsUnchanged() async throws {
        let h = try harness()
        let r6 = try await h.db.write { db -> Int64 in
            try db.execute(sql: Self.sentRoundSQL, arguments: [h.projectID, h.sessionID])
            return db.lastInsertedRowID
        }
        // The previous round marked a.go (key of its blob "h-a.go") and b.go (a stale key).
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let env = try decoder.decode(ReviewEnvelope.self, from: Data(diffJSON(path: "a.go").utf8))
        let keyA = ReviewChangesModel.contentKey(try XCTUnwrap(env.diff?.files.first))
        try await h.db.write { db in
            try ReviewQueries.setViewed(db, roundID: r6, path: "a.go", contentSHA: keyA)
            try ReviewQueries.setViewed(db, roundID: r6, path: "b.go", contentSHA: "stale")
        }
        h.baseScript(id: 7, prev: r6, paths: ["a.go", "b.go"])
        h.cli.script(["diff-since": diffJSON(path: "c.go")])
        await h.model.open()
        XCTAssertTrue(h.model.isViewed("a.go"))
        XCTAssertFalse(h.model.isViewed("b.go"))
        XCTAssertEqual(Set(h.model.viewed.keys), ["a.go"])
        XCTAssertEqual(h.model.files.map(\.path), ["c.go"])
    }

    func testViewedKeyComesFromTheAllDiffInEveryView() async throws {
        let h = try harness()
        h.baseScript(paths: ["a.go", "b.go"])
        h.cli.script(["diff-since": diffJSON(["a.go"], hunk: "since")])
        await h.model.open()
        await h.model.setView(.sinceLastRound)
        try h.model.toggleViewed("a.go")
        XCTAssertTrue(h.model.isViewed("a.go"))
        await h.model.setView(.all)
        XCTAssertTrue(h.model.isViewed("a.go"))
        XCTAssertFalse(h.model.isViewed("b.go"))
    }

    func testDeletingACarriedCommentResolvesItAndReopenDoesNotCarryAgain() async throws {
        let h = try harness()
        let r6 = try await h.db.write { db -> Int64 in
            try db.execute(sql: Self.sentRoundSQL, arguments: [h.projectID, h.sessionID])
            return db.lastInsertedRowID
        }
        try await h.db.write { db in
            let id = try ReviewQueries.addDraft(db, roundID: r6, path: "a.go", side: "new", startLine: 1, endLine: 1,
                                                anchor: ReviewCommentAnchor.anchor(text: "x\n", startLine: 1, endLine: 1),
                                                treeSHA: "t6", body: "b")
            try db.execute(sql: "UPDATE review_comments SET status='sent' WHERE id=?", arguments: [id])
        }
        h.cli.script(["start": startJSON(id: 7, prev: r6), "context": #"{"ok":true,"items":[]}"#, "diff": diffJSON(path: "a.go"),
                      "file": fileJSON(old: "x\n", new: "x\n")])
        await h.model.open()
        let carried = try XCTUnwrap(h.model.comments.first)
        XCTAssertEqual(carried.status, .carried)
        try h.model.deleteComment(id: carried.id)
        await h.model.open()
        let rows = try await h.comments()
        XCTAssertEqual(rows.map(\.status), [.resolved])
    }

    func testOldSideCommentIsRefusedInTheSinceView() async throws {
        let h = try harness()
        h.baseScript()
        h.cli.script(["file": fileJSON(old: "one\n", new: "two\n")])
        await h.model.open()
        await h.model.select("a.go")
        await h.model.setView(.sinceLastRound)
        XCTAssertThrowsError(try h.model.addComment(path: "a.go", side: "old", startLine: 1, endLine: 1, body: "x")) {
            XCTAssertEqual($0 as? ReviewChangesModel.ModelError, .oldSideInSinceView)
        }
        XCTAssertEqual(h.model.lastError, "Switch to All changes to comment on removed lines")
        XCTAssertEqual(h.model.comments, [])
    }

    func testToggleViewedSetsAndClears() async throws {
        let h = try harness()
        h.baseScript()
        await h.model.open()
        try h.model.toggleViewed("a.go")
        XCTAssertTrue(h.model.isViewed("a.go"))
        try h.model.toggleViewed("a.go")
        XCTAssertFalse(h.model.isViewed("a.go"))
        XCTAssertThrowsError(try h.model.toggleViewed("nope.go"))
        XCTAssertNotNil(h.model.lastError)
    }

    func testViewedMarkGoesStaleWhenTheContentChanges() async throws {
        let h = try harness()
        h.baseScript()
        h.cli.script("start", [startJSON(id: 7, prev: 0), startJSON(id: 7, prev: 0, tree: "u")])
        h.cli.script("diff", [diffJSON(path: "a.go"), diffJSON(["a.go"], hunk: "changed")])
        await h.model.open()
        try h.model.toggleViewed("a.go")
        await h.model.refresh()
        XCTAssertFalse(h.model.isViewed("a.go"))
    }

    func testSelectLoadsSidesAndAddCommentAnchorsToThem() async throws {
        let h = try harness()
        h.baseScript()
        h.cli.script(["file": fileJSON(old: "one\n", new: "one\ntwo\nthree\n")])
        await h.model.open()
        await h.model.select("a.go")
        XCTAssertEqual(h.model.sides?.new.text, "one\ntwo\nthree\n")
        try h.model.addComment(path: "a.go", side: "new", startLine: 2, endLine: 2, body: "why?")
        XCTAssertEqual(h.model.draftCount, 1)
        let first = try await h.comments().first
        let row = try XCTUnwrap(first)
        XCTAssertEqual(row.quote, "two")
        XCTAssertEqual(row.treeSHA, "t7")
        try h.model.editComment(id: row.id, body: "why not?")
        XCTAssertEqual(h.model.comments.first?.body, "why not?")
        try h.model.deleteComment(id: row.id)
        XCTAssertEqual(h.model.comments, [])
    }

    func testSwitchingFilesNeverShowsTheOldSidesForTheNewPath() async throws {
        let h = try harness()
        h.baseScript(paths: ["a.go", "b.go"])
        h.cli.script("file", [fileJSON(old: "a\n", new: "a2\n"), fileJSON(old: "b\n", new: "b2\n")])
        await h.model.open()
        await h.model.select("a.go")
        XCTAssertEqual(h.model.currentSides?.new.text, "a2\n")
        h.cli.hold("file")
        let switching = Task { await h.model.select("b.go") }
        await h.cli.waitPending("file")
        XCTAssertEqual(h.model.selectedPath, "b.go")
        XCTAssertNil(h.model.currentSides, "a.go's text must not show as b.go")
        XCTAssertThrowsError(try h.model.addComment(path: "b.go", side: "new", startLine: 1, endLine: 1, body: "x")) {
            XCTAssertEqual($0 as? ReviewChangesModel.ModelError, .fileNotLoaded("b.go"))
        }
        XCTAssertNotNil(h.model.lastError)
        let written = try await h.comments()
        XCTAssertEqual(written, [])
        h.cli.release("file")
        await switching.value
        XCTAssertEqual(h.model.currentSides?.path, "b.go")
        XCTAssertEqual(h.model.currentSides?.new.text, "b2\n")
    }

    func testSidesOfTheOldTreeAreNotCurrentDuringARefresh() async throws {
        let h = try harness()
        h.baseScript()
        h.cli.script("start", [startJSON(id: 7, prev: 0), startJSON(id: 7, prev: 0, tree: "u")])
        h.cli.script("file", [fileJSON(old: "x\n", new: "old\n"), fileJSON(old: "x\n", new: "new\n")])
        await h.model.open()
        await h.model.select("a.go")
        h.cli.hold("file")
        let refresh = Task { await h.model.refresh() }
        await h.cli.waitPending("file")
        XCTAssertEqual(h.model.round?.treeSha, "u7")
        XCTAssertNil(h.model.currentSides)
        XCTAssertThrowsError(try h.model.addComment(path: "a.go", side: "new", startLine: 1, endLine: 1, body: "x"))
        h.cli.release("file")
        await refresh.value
        XCTAssertEqual(h.model.currentSides?.new.text, "new\n")
        XCTAssertEqual(h.model.currentSides?.treeSHA, "u7")
    }

    func testOverlappingRefreshesRunInSequenceAndTheLastTreeWins() async throws {
        let h = try harness()
        h.baseScript()
        h.cli.script("start", [startJSON(id: 7, prev: 0), startJSON(id: 7, prev: 0, tree: "u"), startJSON(id: 7, prev: 0, tree: "v")])
        await h.model.open()
        h.cli.hold("start")
        let first = Task { await h.model.refresh() }
        await h.cli.waitPending("start")
        XCTAssertTrue(h.model.refreshing)
        await h.model.refresh()
        await h.model.refresh()
        XCTAssertEqual(h.cli.calls("start").count, 2, "the calls made meanwhile start nothing")
        h.cli.release("start")
        await first.value
        XCTAssertEqual(h.cli.calls("start").count, 3, "open, the refresh, and exactly one more")
        XCTAssertEqual(h.model.round?.treeSha, "v7")
        XCTAssertFalse(h.model.refreshing)
    }

    func testSendDuringARefreshTypesNothing() async throws {
        let h = try harness()
        h.baseScript()
        h.cli.script(["send": #"{"ok":true,"sent":true,"comments":1,"line":"review 7"}"#])
        await h.model.open()
        h.cli.hold("start")
        let refresh = Task { await h.model.refresh() }
        await h.cli.waitPending("start")
        await h.model.send()
        XCTAssertEqual(h.cli.calls("send"), [])
        XCTAssertEqual(h.sink.lines, [])
        h.cli.release("start")
        await refresh.value
    }

    func testAddCommentOnAFileNotOpenThrows() async throws {
        let h = try harness()
        h.baseScript()
        await h.model.open()
        XCTAssertThrowsError(try h.model.addComment(path: "a.go", side: "new", startLine: 1, endLine: 1, body: "x")) {
            XCTAssertEqual($0 as? ReviewChangesModel.ModelError, .fileNotLoaded("a.go"))
        }
        XCTAssertNotNil(h.model.lastError)
    }

    func testFileFailureSetsLastErrorAndClearsSides() async throws {
        let h = try harness()
        h.baseScript()
        h.cli.script(["file": #"{"ok":false,"error":"path escapes the folder"}"#])
        await h.model.open()
        await h.model.select("a.go")
        XCTAssertNil(h.model.sides)
        XCTAssertEqual(h.model.lastError, "path escapes the folder")
        h.model.clearError()
        XCTAssertNil(h.model.lastError)
    }

    func testSetViewRefetchesTheDiffSince() async throws {
        let h = try harness()
        h.baseScript()
        await h.model.open()
        await h.model.setView(.sinceLastRound)
        XCTAssertEqual(h.model.view, .sinceLastRound)
        let sinceFlags = h.cli.calls("diff").map { $0.contains("--since") }
        XCTAssertEqual(sinceFlags, [false, false, true])
    }

    func testRefreshMovesAndOutdatesDrafts() async throws {
        let h = try harness()
        h.baseScript()
        h.cli.script("start", [startJSON(id: 7, prev: 0), startJSON(id: 7, prev: 0, tree: "u")])
        h.cli.script("file", [fileJSON(old: "x\n", new: "keep\ngone\n"), fileJSON(old: "x\n", new: "added\nkeep\n")])
        await h.model.open()
        await h.model.select("a.go")
        try h.model.addComment(path: "a.go", side: "new", startLine: 1, endLine: 1, body: "moves")
        try h.model.addComment(path: "a.go", side: "new", startLine: 2, endLine: 2, body: "lost")
        await h.model.refresh()
        let rows = try await h.comments()
        XCTAssertEqual(rows.first { $0.body == "moves" }?.startLine, 2)
        XCTAssertEqual(rows.first { $0.body == "moves" }?.treeSHA, "u7")
        XCTAssertEqual(rows.first { $0.body == "moves" }?.status, .draft)
        XCTAssertEqual(rows.first { $0.body == "lost" }?.status, .outdated)
        XCTAssertEqual(h.model.comments, rows)
        XCTAssertNil(h.model.lastError)
    }

    func testResolveClosesAnOutdatedComment() async throws {
        let h = try harness()
        h.baseScript()
        await h.model.open()
        let id = try await h.db.write { db -> Int64 in
            let id = try ReviewQueries.addDraft(db, roundID: 7, path: "a.go", side: "new", startLine: 1, endLine: 1,
                                                anchor: CommentAnchor(quote: "q", prefix: "", suffix: "", heading: ""), treeSHA: "t7", body: "b")
            try ReviewQueries.markOutdated(db, id: id)
            return id
        }
        try h.model.resolve(id: id)
        let resolved = try await h.comments().first?.status
        XCTAssertEqual(resolved, .resolved)
        XCTAssertThrowsError(try h.model.resolve(id: id))
        XCTAssertNotNil(h.model.lastError)
    }

    // MARK: - Deep mode

    private func deepStartJSON(status: String = "open") -> String {
        """
        {"ok":true,"round":{"id":7,"status":"\(status)","mode":"deep","phase":"chapters","chapter_key":"dir:cmd","active_seconds":90,
         "folder_root":"/r","base_sha":"b","base_label":"main","tree_sha":"t7","prev_round_id":0,"prev_tree_sha":"","prev_tree_lost":false}}
        """
    }

    private func deepContextJSON() -> String {
        let lens = #"{"id":"correctness","name":"Correctness","builtin":true,"items":[{"key":"k1","text":"Edge cases?"}]}"#
        return #"{"ok":true,"items":[{"target_id":5,"text":"Ship it","intent":""}],"lenses":[\#(lens)],"lens_notes":["note"]}"#
    }

    private func openDeep(_ h: Harness, paths: [String] = ["cmd/x.go", "pkg/y.go"]) async {
        h.cli.script(["start": deepStartJSON(), "context": deepContextJSON(), "diff": diffJSON(paths)])
        await h.model.open()
    }

    func testOpenRestoresDeepState() async throws {
        let h = try harness()
        await openDeep(h)
        XCTAssertEqual(h.model.mode, .deep)
        XCTAssertEqual(h.model.phase, .chapters)
        XCTAssertEqual(h.model.currentChapterKey, "dir:cmd")
        XCTAssertEqual(h.model.pace.activeSeconds, 90)
        XCTAssertEqual(h.model.lenses.map(\.id), ["correctness"])
        XCTAssertEqual(h.model.lensNotes, ["note"])
        XCTAssertEqual(h.model.chapters.map(\.key), ["dir:cmd", "dir:pkg"])
        XCTAssertEqual(h.model.intentItems.map(\.key), ["target:5"])
    }

    func testModeAndPhasePersistOnOpenRound() async throws {
        let h = try harness()
        h.baseScript()
        await h.model.open()
        try h.model.setMode(.deep)
        try h.model.setPhase(.wrapup)
        let row = try await h.db.read { try Row.fetchOne($0, sql: "SELECT mode, phase FROM review_rounds WHERE id = 7") }
        XCTAssertEqual(row?["mode"] as String?, "deep")
        XCTAssertEqual(row?["phase"] as String?, "wrapup")

        let sent = try harness()
        sent.cli.script(["start": deepStartJSON(status: "sent"), "context": deepContextJSON(), "diff": diffJSON(["cmd/x.go"])])
        await sent.model.open()
        try await sent.db.write { try $0.execute(sql: "UPDATE review_rounds SET status = 'sent', mode = 'quick', phase = ''") }
        XCTAssertThrowsError(try sent.model.setMode(.quick)) { XCTAssertEqual($0 as? ReviewChangesModel.ModelError, .roundClosed) }
        // A sent round moves the phase on screen and writes nothing.
        try sent.model.setPhase(.meaning)
        XCTAssertEqual(sent.model.phase, .meaning)
        XCTAssertEqual(ReviewChangesModel.ModelError.roundClosed.errorDescription, "This round was already sent, so it cannot change.")
        let after = try await sent.db.read { try Row.fetchOne($0, sql: "SELECT mode, phase FROM review_rounds WHERE id = 7") }
        XCTAssertEqual(after?["mode"] as String?, "quick")
        XCTAssertEqual(after?["phase"] as String?, "")
        XCTAssertEqual(sent.model.mode, .deep)
    }

    func testRefreshDropsVanishedChapter() async throws {
        let h = try harness()
        h.cli.script(["start": startJSON(id: 7, prev: 0), "context": #"{"ok":true,"items":[]}"#])
        h.cli.script("diff", [diffJSON(["old/a.go", "new/b.go"]), diffJSON(["new/b.go"])])
        await h.model.open()
        try await h.model.selectChapter("dir:old")
        try h.model.setCheck(chapterKey: "dir:old", lens: "correctness", itemKey: "k1", checked: true)
        XCTAssertEqual(h.model.currentChapterKey, "dir:old")
        await h.model.refresh()
        XCTAssertEqual(h.model.currentChapterKey, "dir:new")
        let rows = try await h.db.read { try ReviewQueries.checks($0, roundID: 7) }
        XCTAssertEqual(rows.map(\.chapterKey), ["dir:old"])
        for chapter in h.model.chapters { XCTAssertTrue(h.model.checks(forChapter: chapter.key).isEmpty) }
    }

    func testSetCheckTicksAndUnticks() async throws {
        let h = try harness()
        await openDeep(h)
        try h.model.setCheck(chapterKey: "dir:cmd", lens: "correctness", itemKey: "k1", checked: true)
        XCTAssertEqual(h.model.checks(forChapter: "dir:cmd").map(\.state), [.checked])
        try h.model.setCheck(chapterKey: "dir:cmd", lens: "correctness", itemKey: "k1", checked: false)
        XCTAssertTrue(h.model.checks.isEmpty)
    }

    func testCommentOnCheckWritesLensCommentAndMarksCheck() async throws {
        let h = try harness()
        await openDeep(h)
        let item = try XCTUnwrap(h.model.lenses.first?.items.first)
        try h.model.commentOnCheck(chapterKey: "dir:cmd", lens: "correctness", item: item, body: "What about nil?")
        let rows = try await h.comments()
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].path)
        XCTAssertEqual(rows[0].lens, "correctness")
        XCTAssertEqual(rows[0].body, "What about nil?")
        XCTAssertEqual(rows[0].status, .draft)
        XCTAssertEqual(h.model.checks(forChapter: "dir:cmd").map(\.state), [.commented])
        XCTAssertEqual(h.model.comments, rows)
    }

    func testMarkIntentNotDoneAddsIntentComment() async throws {
        let h = try harness()
        await openDeep(h)
        let item = try XCTUnwrap(h.model.intentItems.first)
        try h.model.markIntent(item, state: .notDone, note: "missing")
        try h.model.markIntent(ReviewIntentItem(key: "target:6", text: "Other"), state: .partial, note: "")
        let rows = try await h.comments()
        XCTAssertEqual(rows.map(\.lens), ["intent", "intent"])
        XCTAssertEqual(rows[0].body, ReviewWrapUp.intentCommentBody(partial: false, item: item, note: "missing"))
        XCTAssertTrue(rows[1].body.hasPrefix("Partly done"))
        XCTAssertEqual(h.model.checks(forChapter: "wrapup").map(\.state), [.notDone, .partial])
        XCTAssertEqual(h.model.checks(forChapter: "wrapup").map(\.lens), ["intent", "intent"])
    }

    func testMarkIntentDoneAddsNoComment() async throws {
        let h = try harness()
        await openDeep(h)
        let item = try XCTUnwrap(h.model.intentItems.first)
        try h.model.markIntent(item, state: .done, note: "")
        let rows = try await h.comments()
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(h.model.checks(forChapter: "wrapup").map(\.state), [.done])
    }

    func testRemarkingIntentReplacesItsDraft() async throws {
        let h = try harness()
        await openDeep(h)
        let item = try XCTUnwrap(h.model.intentItems.first)
        try h.model.markIntent(item, state: .notDone, note: "missing")
        try h.model.markIntent(item, state: .partial, note: "half")
        let rows = try await h.comments().filter { $0.lens == "intent" && $0.status == .draft }
        XCTAssertEqual(rows.map(\.body), [ReviewWrapUp.intentCommentBody(partial: true, item: item, note: "half")])
    }

    func testMarkingDoneRemovesTheIntentDraft() async throws {
        let h = try harness()
        await openDeep(h)
        let item = try XCTUnwrap(h.model.intentItems.first)
        try h.model.markIntent(item, state: .notDone, note: "")
        try h.model.markIntent(item, state: .done, note: "")
        let rows = try await h.comments()
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(h.model.comments, rows)
    }

    func testRemarkingIntentLeavesAnotherItemsDraftAlone() async throws {
        let h = try harness()
        await openDeep(h)
        let item = try XCTUnwrap(h.model.intentItems.first)
        let other = ReviewIntentItem(key: "target:6", text: "Other")
        try h.model.markIntent(other, state: .notDone, note: "x")
        try h.model.markIntent(item, state: .notDone, note: "a")
        try h.model.markIntent(item, state: .partial, note: "b")
        let bodies = try await h.comments().filter { $0.status == .draft }.map(\.body)
        XCTAssertEqual(bodies, [
            ReviewWrapUp.intentCommentBody(partial: false, item: other, note: "x"),
            ReviewWrapUp.intentCommentBody(partial: true, item: item, note: "b")
        ])
    }

    func testRemarkingIntentReplacesAnEmojiTitleDraft() async throws {
        let h = try harness()
        await openDeep(h)
        for text in ["Ship 🚀 e\u{301}", "Ship 🚀 e\u{301}"] {
            try h.model.markIntent(ReviewIntentItem(key: "target:9", text: text), state: .notDone, note: "n")
        }
        let drafts = try await h.comments().filter { $0.status == .draft }
        XCTAssertEqual(drafts.count, 1)
    }

    func testMarkingDoneInRound2ResolvesTheCarriedNotDone() async throws {
        let h = try harness()
        let item = ReviewIntentItem(key: "target:5", text: "Ship it")
        h.cli.script(["start": startJSON(id: 8, prev: 7), "context": deepContextJSON(), "diff": diffJSON(["cmd/x.go"])])
        try await h.db.write { db in
            try db.execute(sql: """
                INSERT INTO review_rounds (id, project_id, session_id, folder_root, base_sha, tree_sha, status)
                VALUES (7, ?, ?, '/r', 'b', 't7', 'sent')
                """, arguments: [h.projectID, h.sessionID])
            try db.execute(sql: """
                INSERT INTO review_comments (round_id, path, side, start_line, end_line, tree_sha, lens, body, status)
                VALUES (7, NULL, 'new', 0, 0, 't7', 'intent', ?, 'sent')
                """, arguments: [ReviewWrapUp.intentCommentBody(partial: false, item: item, note: "gone")])
        }
        await h.model.open()
        let carried = try await h.comments(8).filter { $0.status == .carried }
        XCTAssertEqual(carried.count, 1)
        try h.model.markIntent(item, state: .done, note: "")
        let rows = try await h.comments(8)
        XCTAssertEqual(rows.map(\.status), [.resolved])
    }

    func testRefreshRereadsTheContext() async throws {
        let h = try harness()
        await openDeep(h)
        let lens = #"{"id":"tests","name":"Tests","builtin":true,"items":[{"key":"z","text":"Z?"}]}"#
        let changed = #"{"ok":true,"items":[],"lenses":[\#(lens)],"lens_notes":[]}"#
        h.cli.script(["context": changed])
        await h.model.refresh()
        XCTAssertEqual(h.model.lenses.map(\.id), ["tests"])
        XCTAssertTrue(h.model.lensNotes.isEmpty)
        XCTAssertTrue(h.model.intentItems.isEmpty)
    }

    func testChecklistWritesRollBackWhenTheRowWasSentBehindTheModel() async throws {
        let actions: [(ReviewChangesModel) throws -> Void] = [
            { m in
                let item = try XCTUnwrap(m.lenses.first?.items.first)
                try m.commentOnCheck(chapterKey: "dir:cmd", lens: "correctness", item: item, body: "B")
            },
            { m in try m.markIntent(try XCTUnwrap(m.intentItems.first), state: .done, note: "") },
            { m in try m.setCheck(chapterKey: "dir:cmd", lens: "correctness", itemKey: "k1", checked: true) }
        ]
        for action in actions {
            let h = try harness()
            await openDeep(h)
            let intent = try XCTUnwrap(h.model.intentItems.first)
            try h.model.markIntent(intent, state: .notDone, note: "keep")
            try await h.db.write { try $0.execute(sql: "UPDATE review_rounds SET status = 'sent'") }
            XCTAssertThrowsError(try action(h.model)) { XCTAssertEqual($0 as? ReviewChangesModel.ModelError, .roundClosed) }
            XCTAssertEqual(h.model.round?.status, "sent")
            let rows = try await h.comments()
            XCTAssertEqual(rows.map(\.status), [.draft])
            XCTAssertEqual(rows.map(\.lens), ["intent"])
            let checks = try await h.db.read { try ReviewQueries.checks($0, roundID: 7) }
            XCTAssertEqual(checks.map(\.itemKey), [intent.key])
            XCTAssertEqual(checks.map(\.state), [.notDone])
        }
    }

    func testSetModeThrowsWhenTheRowWasSentBehindTheModel() async throws {
        let h = try harness()
        h.baseScript()
        await h.model.open()
        try await h.db.write { try $0.execute(sql: "UPDATE review_rounds SET status = 'sent'") }
        XCTAssertThrowsError(try h.model.setMode(.deep)) { XCTAssertEqual($0 as? ReviewChangesModel.ModelError, .roundClosed) }
        let mode = try await h.db.read { try String.fetchOne($0, sql: "SELECT mode FROM review_rounds WHERE id = 7") }
        XCTAssertEqual(mode, "quick")
        XCTAssertEqual(h.model.round?.status, "sent")
        XCTAssertEqual(h.model.mode, .quick)
    }

    func testOpenResetsBreakHintDismissed() async throws {
        let h = try harness()
        h.baseScript()
        await h.model.open()
        h.model.breakHintDismissed = true
        await h.model.open()
        XCTAssertFalse(h.model.breakHintDismissed)
    }

    private func activeSeconds(_ h: Harness) async throws -> Int? {
        try await h.db.read { try Int.fetchOne($0, sql: "SELECT active_seconds FROM review_rounds WHERE id = 7") }
    }

    func testActiveTimePersistsEvery30Seconds() async throws {
        let h = try harness()
        h.baseScript()
        await h.model.open()
        // open() noted an interaction at real now; the fixed t0 below replaces it, and the first tick only sets the baseline.
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        h.model.noteInteraction(at: t0)
        h.model.tick(at: t0, isKey: true)
        for step in stride(from: 10, through: 29, by: 10) {
            h.model.noteInteraction(at: t0.addingTimeInterval(Double(step)))
            h.model.tick(at: t0.addingTimeInterval(Double(step)), isKey: true)
        }
        h.model.noteInteraction(at: t0.addingTimeInterval(29))
        h.model.tick(at: t0.addingTimeInterval(29), isKey: true)
        XCTAssertEqual(h.model.pace.activeSeconds, 29)
        let early = try await activeSeconds(h)
        XCTAssertEqual(early, 0)
        h.model.noteInteraction(at: t0.addingTimeInterval(30))
        h.model.tick(at: t0.addingTimeInterval(30), isKey: true)
        let at30 = try await activeSeconds(h)
        XCTAssertEqual(at30, 30)
        h.model.noteInteraction(at: t0.addingTimeInterval(41))
        h.model.tick(at: t0.addingTimeInterval(41), isKey: true)
        h.model.flushState()
        let at41 = try await activeSeconds(h)
        XCTAssertEqual(at41, 41)
    }

    func testSendFlushesState() async throws {
        let h = try harness()
        h.baseScript()
        h.cli.script(["send": #"{"ok":true,"sent":false}"#])
        await h.model.open()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        h.model.noteInteraction(at: t0)
        h.model.tick(at: t0, isKey: true)
        h.model.noteInteraction(at: t0.addingTimeInterval(12))
        h.model.tick(at: t0.addingTimeInterval(12), isKey: true)
        let before = try await activeSeconds(h)
        XCTAssertEqual(before, 0)
        await h.model.send()
        XCTAssertEqual(h.cli.activeSecondsAtSend, 12)
    }
}

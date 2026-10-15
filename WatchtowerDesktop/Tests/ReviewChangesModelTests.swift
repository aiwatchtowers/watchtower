import GRDB
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Answers `workbench review <sub> …` from a script keyed by the subcommand
/// (`args[2]`): one answer per call, the last repeating. A served `start`
/// makes the round row exist, as Go's does.
private final class ScriptedRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [String: [String]] = [:]
    private var served: [String: Int] = [:]
    private var seen: [[String]] = []
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

    func run(args: [String]) async throws -> Data {
        let sub = args[2]
        let answer: String = lock.withLock {
            seen.append(args)
            let list = script[sub] ?? [#"{"ok":false,"error":"unscripted \#(sub)"}"#]
            let n = served[sub, default: 0]
            served[sub] = n + 1
            return list[min(n, list.count - 1)]
        }
        if sub == "start" { try seedRound(answer) }
        return Data(answer.utf8)
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

private func diffJSON(_ paths: [String], hunk: String = "h") -> String {
    let hunkFields = #""header":"@@ -1 +1 @@","old_start":1,"old_lines":1,"new_start":1,"new_lines":1,"lines":["-a","+b"]"#
    let entries: [String] = paths.map { path in
        """
        {"path":"\(path)","status":"modified","additions":1,"deletions":1,"binary":false,
         "hunks":[{"hunk_id":"\(hunk)-\(path)",\(hunkFields)}]}
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

    func testSendTwiceTypesOnce() async throws {
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
        XCTAssertNil(h.model.lastError)
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
        XCTAssertTrue(h.cli.calls("diff").first?.contains("--since") == true)
    }

    func testNewRoundKeepsViewedMarksWhoseHunksAreUnchanged() async throws {
        let h = try harness()
        let r6 = try await h.db.write { db -> Int64 in
            try db.execute(sql: Self.sentRoundSQL, arguments: [h.projectID, h.sessionID])
            return db.lastInsertedRowID
        }
        // The previous round marked a.go (key of hunk "h-a.go") and b.go (a stale key).
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let env = try decoder.decode(ReviewEnvelope.self, from: Data(diffJSON(path: "a.go").utf8))
        let keyA = ReviewChangesModel.contentKey(try XCTUnwrap(env.diff?.files.first))
        try await h.db.write { db in
            try ReviewQueries.setViewed(db, roundID: r6, path: "a.go", contentSHA: keyA)
            try ReviewQueries.setViewed(db, roundID: r6, path: "b.go", contentSHA: "stale")
        }
        h.baseScript(id: 7, prev: r6, paths: ["a.go", "b.go"])
        await h.model.open()
        XCTAssertTrue(h.model.isViewed("a.go"))
        XCTAssertFalse(h.model.isViewed("b.go"))
        XCTAssertEqual(Set(h.model.viewed.keys), ["a.go"])
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

    func testViewedMarkGoesStaleWhenTheHunksChange() async throws {
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
    }

    func testSetViewRefetchesTheDiffSince() async throws {
        let h = try harness()
        h.baseScript()
        await h.model.open()
        await h.model.setView(.sinceLastRound)
        XCTAssertEqual(h.model.view, .sinceLastRound)
        XCTAssertEqual(h.cli.calls("diff").count, 2)
        XCTAssertTrue(h.cli.calls("diff")[1].contains("--since"))
        XCTAssertFalse(h.cli.calls("diff")[0].contains("--since"))
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
}

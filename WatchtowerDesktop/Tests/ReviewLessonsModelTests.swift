import GRDB
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Answers `workbench review lessons <action> …` (`args[3]`) with a fixed
/// envelope and, like Go, writes the rows the action changes.
private final class LessonsRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: String] = [:]
    private var effects: [String: (Database) throws -> Void] = [:]
    private var seen: [[String]] = []
    private let db: DatabasePool

    init(db: DatabasePool) { self.db = db }

    func answer(_ action: String, _ json: String, effect: ((Database) throws -> Void)? = nil) {
        lock.withLock {
            answers[action] = json
            effects[action] = effect
        }
    }

    var calls: [[String]] { lock.withLock { seen } }

    func run(args: [String]) async throws -> Data {
        let action = args[3]
        let (json, effect) = lock.withLock { () -> (String, ((Database) throws -> Void)?) in
            seen.append(args)
            return (answers[action] ?? #"{"ok":false,"error":"unscripted \#(action)"}"#, effects[action])
        }
        if let effect { try await db.write(effect) }
        return Data(json.utf8)
    }
}

@MainActor
final class ReviewLessonsModelTests: XCTestCase {
    private var paths: [String] = []

    override func tearDown() {
        paths.forEach { TestDatabase.cleanup(path: $0) }
        paths = []
        super.tearDown()
    }

    private func make() throws -> (ReviewLessonsModel, LessonsRunner, DatabasePool, Int64) {
        let (pool, path) = try TestDatabase.createPool()
        paths.append(path)
        let project = try pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: "/tmp/acme") }
        let runner = LessonsRunner(db: pool)
        return (ReviewLessonsModel(projectID: project, cli: WorkbenchCLI(runner: runner), db: pool), runner, pool, project)
    }

    nonisolated private static func insertLesson(project: Int64, text: String) -> (Database) throws -> Void {
        { db in
            try db.execute(sql: """
                INSERT INTO review_lessons (project_id, lens, text, source_comment_ids) VALUES (?, 'house_rules', ?, '[1,2]')
                """, arguments: [project, text])
        }
    }

    func testFindRepeatsListsProposals() async throws {
        let (model, runner, _, project) = try make()
        runner.answer("propose", #"{"ok":true,"lessons":[]}"#, effect: Self.insertLesson(project: project, text: "Wrap errors"))
        XCTAssertFalse(model.finding)
        await model.findRepeats()
        XCTAssertFalse(model.finding)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.lessons.map(\.text), ["Wrap errors"])
        XCTAssertEqual(model.lessons.first?.sourceCommentIDs, [1, 2])
        XCTAssertEqual(runner.calls.first, ["workbench", "review", "lessons", "propose", "--workbench", String(project), "--json"])
    }

    func testAcceptAndDismissReload() async throws {
        let (model, runner, db, project) = try make()
        try await db.write { db in
            try Self.insertLesson(project: project, text: "A")(db)
            try Self.insertLesson(project: project, text: "B")(db)
        }
        try model.load()
        let ids = model.lessons.map(\.id)
        XCTAssertEqual(ids.count, 2)
        runner.answer("accept", #"{"ok":true,"written":"/tmp/acme/.watchtower/review.md"}"#) { db in
            try db.execute(sql: "UPDATE review_lessons SET status = 'accepted' WHERE id = ?", arguments: [ids[0]])
        }
        await model.accept(ids[0])
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.lessons.map(\.id), [ids[1]])
        runner.answer("dismiss", #"{"ok":true}"#) { db in
            try db.execute(sql: "UPDATE review_lessons SET status = 'dismissed' WHERE id = ?", arguments: [ids[1]])
        }
        await model.dismiss(ids[1])
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.lessons, [])
        XCTAssertEqual(runner.calls.map { Array($0.prefix(4)) }.map(\.last), ["accept", "dismiss"])
        XCTAssertEqual(runner.calls.last?.suffix(3), ["--lesson", String(ids[1]), "--json"])
    }

    func testAcceptRefusalSetsLastError() async throws {
        let (model, runner, db, project) = try make()
        try await db.write { try Self.insertLesson(project: project, text: "A")($0) }
        try model.load()
        let id = try XCTUnwrap(model.lessons.first?.id)
        runner.answer("accept", #"{"ok":false,"error":".watchtower/review.md is a symlink; nothing was written"}"#)
        await model.accept(id)
        XCTAssertEqual(model.lastError, ".watchtower/review.md is a symlink; nothing was written")
        XCTAssertEqual(model.lessons.map(\.id), [id], "the lesson stays proposed")
        // The next action clears the old error.
        runner.answer("dismiss", #"{"ok":true}"#)
        await model.dismiss(id)
        XCTAssertNil(model.lastError)
    }
}

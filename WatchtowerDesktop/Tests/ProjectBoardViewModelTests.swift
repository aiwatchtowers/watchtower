import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

@MainActor
final class ProjectBoardViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    // MARK: - Fixtures (raw SQL: the board must work on rows the Go side wrote)

    nonisolated private static func insertProject(_ db: Database, name: String = "acme") throws -> Int64 {
        try db.execute(
            sql: "INSERT INTO projects (name, folder_path) VALUES (?, ?)",
            arguments: [name, "/tmp/\(name)-\(UUID().uuidString)"]
        )
        return db.lastInsertedRowID
    }

    nonisolated private static func insertTarget(
        _ db: Database, project: Int64, text: String, parent: Int64? = nil, status: String = "todo"
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO targets (text, level, custom_label, period_start, period_end,
                    parent_id, status, source_type, ownership, project_id)
                VALUES (?, 'custom', 'project', '2026-09-29', '2026-09-29', ?, ?, 'chat', 'mine', ?)
                """,
            arguments: [text, parent, status, project]
        )
        return db.lastInsertedRowID
    }

    nonisolated private static func insertComment(
        _ db: Database, project: Int64, target: Int64, author: String, body: String, parent: Int64? = nil
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO project_comments (project_id, target_id, parent_id, author, body)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [project, target, parent, author, body]
        )
        return db.lastInsertedRowID
    }

    private func makeVM(project: Int64) -> ProjectBoardViewModel {
        ProjectBoardViewModel(dbPool: dbManager.dbPool, projectID: project)
    }

    // MARK: - Tree

    func testLoadBuildsTheTreeForThisProjectOnly() throws {
        let (pid, feature, task) = try dbManager.dbPool.write { db -> (Int64, Int64, Int64) in
            let pid = try Self.insertProject(db)
            let other = try Self.insertProject(db, name: "other")
            let feature = try Self.insertTarget(db, project: pid, text: "Feature")
            let task = try Self.insertTarget(db, project: pid, text: "Task 1", parent: feature)
            _ = try Self.insertTarget(db, project: other, text: "Foreign")
            return (pid, feature, task)
        }
        let vm = makeVM(project: pid)
        vm.load()

        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.rows.map(\.id), [Int(feature), Int(task)])
        XCTAssertEqual(vm.rows.map(\.depth), [0, 1])
    }

    // MARK: - Status / title edits

    func testSetStatusWritesTheSelectedTargetAndReloads() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            return (pid, try Self.insertTarget(db, project: pid, text: "Task"))
        }
        let vm = makeVM(project: pid)
        vm.load()
        vm.select(Int(tid))
        vm.setStatus("in_progress")

        let stored = try dbManager.dbPool.read { try TargetQueries.fetchByID($0, id: Int(tid)) }
        XCTAssertEqual(stored?.status, "in_progress")
        XCTAssertEqual(vm.selectedNode?.target.status, "in_progress")
    }

    func testSetStatusRejectsAStatusTheBoardDoesNotOffer() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            return (pid, try Self.insertTarget(db, project: pid, text: "Task"))
        }
        let vm = makeVM(project: pid)
        vm.load()
        vm.select(Int(tid))
        vm.setStatus("snoozed")

        let stored = try dbManager.dbPool.read { try TargetQueries.fetchByID($0, id: Int(tid)) }
        XCTAssertEqual(stored?.status, "todo")
    }

    func testRenameTrimsAndIgnoresBlank() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            return (pid, try Self.insertTarget(db, project: pid, text: "Old"))
        }
        let vm = makeVM(project: pid)
        vm.load()
        vm.select(Int(tid))
        vm.rename("   ")
        XCTAssertEqual(vm.selectedNode?.target.text, "Old")
        vm.rename("  New title \n")
        XCTAssertEqual(vm.selectedNode?.target.text, "New title")
    }

    // MARK: - Comments

    func testAddCommentCreatesAnOwnerRootOnTheSelectedTarget() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            return (pid, try Self.insertTarget(db, project: pid, text: "Task"))
        }
        let vm = makeVM(project: pid)
        vm.load()
        vm.select(Int(tid))
        XCTAssertTrue(vm.addComment("  Use the v2 endpoint  "))

        XCTAssertEqual(vm.threads.count, 1)
        XCTAssertEqual(vm.threads.first?.root.author, "owner")
        XCTAssertEqual(vm.threads.first?.root.body, "Use the v2 endpoint")
        XCTAssertEqual(vm.selectedNode?.openComments, 1)
    }

    /// A failed comment write reports `false` so the board composer keeps the
    /// owner's draft, and surfaces the error.
    func testAddCommentReportsAFailedWriteAndKeepsTheDraft() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            return (pid, try Self.insertTarget(db, project: pid, text: "Task"))
        }
        let vm = makeVM(project: pid)
        var reported = 0
        vm.onOwnerWrite = { _, _ in reported += 1 }
        vm.load()
        vm.select(Int(tid))
        try dbManager.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_comment_insert BEFORE INSERT ON project_comments
                BEGIN SELECT RAISE(ABORT, 'disk full'); END
                """)
        }

        XCTAssertFalse(vm.addComment("Use the v2 endpoint"), "a failed write must not tell the composer to clear")
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(reported, 0)
        XCTAssertTrue(vm.threads.isEmpty)
    }

    func testReplyAndResolveAThread() throws {
        let (pid, tid, root) = try dbManager.dbPool.write { db -> (Int64, Int64, Int64) in
            let pid = try Self.insertProject(db)
            let tid = try Self.insertTarget(db, project: pid, text: "Task")
            let root = try Self.insertComment(db, project: pid, target: tid, author: "agent", body: "Which API?")
            return (pid, tid, root)
        }
        let vm = makeVM(project: pid)
        vm.load()
        vm.select(Int(tid))
        vm.reply(to: root, body: "v2")
        vm.setThreadStatus(rootID: root, status: "resolved")

        XCTAssertEqual(vm.threads.first?.replies.map(\.body), ["v2"])
        XCTAssertEqual(vm.threads.first?.root.status, "resolved")
    }

    func testEveryOwnerWriteReportsItsTargetToTheNotificationHook() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            return (pid, try Self.insertTarget(db, project: pid, text: "Task"))
        }
        let vm = makeVM(project: pid)
        var reported: [ProjectSubject] = []
        vm.onOwnerWrite = { project, subject in
            XCTAssertEqual(project, pid)
            reported.append(subject)
        }
        vm.load()
        vm.select(Int(tid))
        vm.setStatus("done")
        vm.rename("Renamed")
        vm.addComment("note")
        let root = try XCTUnwrap(vm.threads.first?.root.id)
        vm.reply(to: root, body: "more")
        vm.setThreadStatus(rootID: root, status: "resolved")

        XCTAssertEqual(reported, Array(repeating: .target(tid), count: 5),
                       "an owner-set done must never notify as if the agent did it")
    }

    func testAFailedWriteDoesNotReportToTheHook() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            return (pid, try Self.insertTarget(db, project: pid, text: "Task"))
        }
        let vm = makeVM(project: pid)
        var reported = 0
        vm.onOwnerWrite = { _, _ in reported += 1 }
        vm.load()
        vm.select(Int(tid))
        let replied = vm.reply(to: 999_999, body: "orphan")   // no such root: ProjectQueries.reply throws
        XCTAssertFalse(replied, "a failed reply reports false so the thread keeps the owner's draft")
        XCTAssertEqual(reported, 0)
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - Mark read

    func testSelectingATargetMarksItsAgentCommentsRead() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            let tid = try Self.insertTarget(db, project: pid, text: "Task")
            _ = try Self.insertComment(db, project: pid, target: tid, author: "agent", body: "Blocked on keys")
            return (pid, tid)
        }
        let vm = makeVM(project: pid)
        vm.load()
        XCTAssertEqual(vm.rows.first?.node.unreadForOwner, 1)

        vm.select(Int(tid))

        let unread = try dbManager.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project_comments WHERE author = 'agent' AND read_at = ''")
        }
        XCTAssertEqual(unread, 0)
        XCTAssertEqual(vm.rows.first?.node.unreadForOwner, 0)
    }

    func testMarkReadFailureKeepsTheUnreadBadge() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            let tid = try Self.insertTarget(db, project: pid, text: "Task")
            _ = try Self.insertComment(db, project: pid, target: tid, author: "agent", body: "Question")
            // Any UPDATE of project_comments fails: models a locked/readonly DB.
            try db.execute(sql: """
                CREATE TRIGGER fail_mark_read BEFORE UPDATE ON project_comments
                BEGIN SELECT RAISE(ABORT, 'mark read refused'); END
                """)
            return (pid, tid)
        }
        let vm = makeVM(project: pid)
        vm.load()
        vm.select(Int(tid))

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(vm.rows.first?.node.unreadForOwner, 1, "the badge drops only after the write succeeds")
    }

    // MARK: - Out-of-process refresh

    func testRefreshIfChangedSeesAWriteFromAnotherConnection() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            return (pid, try Self.insertTarget(db, project: pid, text: "Task"))
        }
        let vm = makeVM(project: pid)
        vm.load()
        XCTAssertFalse(vm.refreshIfChanged(), "nothing changed yet")

        // A second pool on the same file stands in for `watchtower mcp --project`:
        // ValueObservation on dbManager.dbPool would never see this write.
        let foreign = try DatabasePool(path: dbPath)
        try foreign.write { db in
            try db.execute(sql: "UPDATE targets SET status = 'done', updated_at = '2099-01-01T00:00:00Z' WHERE id = ?",
                           arguments: [tid])
            _ = try Self.insertComment(db, project: pid, target: tid, author: "agent", body: "Done: shipped")
        }

        XCTAssertTrue(vm.refreshIfChanged())
        vm.showDone = true
        XCTAssertEqual(vm.rows.first?.node.target.status, "done")
        XCTAssertEqual(vm.rows.first?.node.unreadForOwner, 1)
    }
}

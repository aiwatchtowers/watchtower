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

    func testSetPriorityWritesTheSelectedTargetAndRejectsOthers() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            return (pid, try Self.insertTarget(db, project: pid, text: "Task"))
        }
        let vm = makeVM(project: pid)
        vm.load()
        vm.select(Int(tid))
        vm.setPriority("high")
        XCTAssertEqual(vm.selectedNode?.target.priority, "high")
        vm.setPriority("urgent")

        let stored = try dbManager.dbPool.read { try TargetQueries.fetchByID($0, id: Int(tid)) }
        XCTAssertEqual(stored?.priority, "high")
        XCTAssertNil(vm.errorMessage)
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

    /// Closing the detail card keeps an error raised from it: the board's
    /// banner shows it once the card is gone.
    func testCloseDetailKeepsTheCardsError() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            let tid = try Self.insertTarget(db, project: pid, text: "Task")
            _ = try Self.insertComment(db, project: pid, target: tid, author: "agent", body: "Question")
            try db.execute(sql: """
                CREATE TRIGGER fail_comment_insert BEFORE INSERT ON project_comments
                BEGIN SELECT RAISE(ABORT, 'disk full'); END
                """)
            return (pid, tid)
        }
        let vm = makeVM(project: pid)
        vm.load()
        vm.select(Int(tid))
        XCTAssertFalse(vm.addComment("Reply"))
        let error = try XCTUnwrap(vm.errorMessage)

        vm.closeDetail()

        XCTAssertNil(vm.selectedTargetID)
        XCTAssertNil(vm.selectedNode)
        XCTAssertTrue(vm.threads.isEmpty)
        XCTAssertEqual(vm.selectedImages, [])
        XCTAssertEqual(vm.errorMessage, error, "closing the card must not swallow its error")
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

    /// PROJ-05: closing the last open child also closes its parents in the
    /// same write (migration 00085). Those parents are the owner's doing, so
    /// the hook names them too and no "target done" notice fires for them.
    func testStatusWriteReportsTheParentsTheRollupMoved() throws {
        let (pid, root, mid, leaf) = try dbManager.dbPool.write { db -> (Int64, Int64, Int64, Int64) in
            let pid = try Self.insertProject(db)
            let root = try Self.insertTarget(db, project: pid, text: "Plan")
            let mid = try Self.insertTarget(db, project: pid, text: "Feature", parent: root)
            let leaf = try Self.insertTarget(db, project: pid, text: "Task", parent: mid)
            return (pid, root, mid, leaf)
        }
        let vm = makeVM(project: pid)
        var reported: [ProjectSubject] = []
        vm.onOwnerWrite = { _, subject in reported.append(subject) }
        vm.load()
        vm.select(Int(leaf))
        vm.setStatus("done")

        XCTAssertEqual(mid, root + 1, "fixture: the parents are reported in id order")
        XCTAssertEqual(reported, [.target(leaf), .target(root), .target(mid)])
    }

    // MARK: - Kanban drag (setStatus for a target other than the selected one)

    /// A kanban drop moves the dragged card, not the selected one; the hook
    /// names the dragged card and the parents its rollup moved.
    func testSetStatusForANonSelectedTargetWritesItAndReportsIt() throws {
        let (pid, root, leaf, other) = try dbManager.dbPool.write { db -> (Int64, Int64, Int64, Int64) in
            let pid = try Self.insertProject(db)
            let root = try Self.insertTarget(db, project: pid, text: "Feature")
            let leaf = try Self.insertTarget(db, project: pid, text: "Task", parent: root)
            let other = try Self.insertTarget(db, project: pid, text: "Selected")
            return (pid, root, leaf, other)
        }
        let vm = makeVM(project: pid)
        var reported: [ProjectSubject] = []
        vm.load()
        vm.select(Int(other))
        vm.onOwnerWrite = { _, subject in reported.append(subject) }
        XCTAssertTrue(vm.setStatus("done", for: Int(leaf)))

        let stored = try dbManager.dbPool.read { db in
            (try TargetQueries.fetchByID(db, id: Int(leaf))?.status,
             try TargetQueries.fetchByID(db, id: Int(root))?.status,
             try TargetQueries.fetchByID(db, id: Int(other))?.status)
        }
        XCTAssertEqual(stored.0, "done")
        XCTAssertEqual(stored.1, "done", "PROJ-05: the parent rolls up")
        XCTAssertEqual(stored.2, "todo", "the selected target is untouched")
        XCTAssertEqual(reported, [.target(leaf), .target(root)])
        XCTAssertEqual(vm.selectedTargetID, Int(other), "a drop does not change the selection")
    }

    func testSetStatusToTheCurrentStatusWritesNothing() throws {
        let (pid, tid) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            return (pid, try Self.insertTarget(db, project: pid, text: "Task", status: "in_progress"))
        }
        let vm = makeVM(project: pid)
        var reported = 0
        vm.onOwnerWrite = { _, _ in reported += 1 }
        vm.load()
        let pool = dbManager.dbPool
        let historyRows = {
            try pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM target_status_history WHERE target_id = ?", arguments: [tid])
            }
        }
        let before = try historyRows()
        XCTAssertFalse(vm.setStatus("in_progress", for: Int(tid)))
        XCTAssertEqual(try historyRows(), before, "no status write, so no history row")
        XCTAssertEqual(reported, 0)

        // The menu path goes through the same writer: picking the current
        // status is a no-op there too.
        vm.select(Int(tid))
        vm.setStatus("in_progress")
        XCTAssertEqual(try historyRows(), before)
        XCTAssertEqual(reported, 0)
    }

    func testSetStatusRefusesATargetOfAnotherProject() throws {
        let (pid, foreign) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let pid = try Self.insertProject(db)
            _ = try Self.insertTarget(db, project: pid, text: "Mine")
            let other = try Self.insertProject(db, name: "other")
            return (pid, try Self.insertTarget(db, project: other, text: "Foreign"))
        }
        let vm = makeVM(project: pid)
        var reported = 0
        vm.onOwnerWrite = { _, _ in reported += 1 }
        vm.load()
        XCTAssertFalse(vm.setStatus("done", for: Int(foreign)))

        let stored = try dbManager.dbPool.read { try TargetQueries.fetchByID($0, id: Int(foreign)) }
        XCTAssertEqual(stored?.status, "todo")
        XCTAssertEqual(reported, 0)
    }

    func testSetStatusForAnUnknownTargetWritesNothing() throws {
        let pid = try dbManager.dbPool.write { try Self.insertProject($0) }
        let vm = makeVM(project: pid)
        var reported = 0
        vm.onOwnerWrite = { _, _ in reported += 1 }
        vm.load()
        vm.setStatus("done", for: 999_999)
        XCTAssertEqual(reported, 0)
    }

    func testModeAndKanbanFilterAreRememberedPerProject() throws {
        let suite = "ProjectBoardViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pid = try dbManager.dbPool.write { try Self.insertProject($0) }

        let vm = ProjectBoardViewModel(dbPool: dbManager.dbPool, projectID: pid, defaults: defaults)
        XCTAssertEqual(vm.mode, .list)
        vm.mode = .kanban
        vm.kanbanFilterRootID = 7

        let reopened = ProjectBoardViewModel(dbPool: dbManager.dbPool, projectID: pid, defaults: defaults)
        XCTAssertEqual(reopened.mode, .kanban)
        XCTAssertEqual(reopened.kanbanFilterRootID, 7)
        let other = ProjectBoardViewModel(dbPool: dbManager.dbPool, projectID: pid + 1, defaults: defaults)
        XCTAssertEqual(other.mode, .list)
        XCTAssertNil(other.kanbanFilterRootID)
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

    func testSelectedTargetsImagesLoadAndAnAgentAttachIsPickedUp() throws {
        let (pid, tid, other) = try dbManager.dbPool.write { db -> (Int64, Int64, Int64) in
            let pid = try Self.insertProject(db)
            let tid = try Self.insertTarget(db, project: pid, text: "Bug")
            let other = try Self.insertTarget(db, project: pid, text: "Other")
            try TestDatabase.insertProjectTargetImage(db, projectID: pid, targetID: other, sha256: "o")
            return (pid, tid, other)
        }
        let vm = makeVM(project: pid)
        vm.load()
        vm.select(Int(tid))
        XCTAssertEqual(vm.selectedImages, [], "another target's image never shows")

        let foreign = try DatabasePool(path: dbPath)
        try foreign.write { db in
            try TestDatabase.insertProjectTargetImage(db, projectID: pid, targetID: tid, fileName: "shot.png", sha256: "s")
        }
        XCTAssertTrue(vm.refreshIfChanged(), "an attach from the agent's process changes the fingerprint")
        XCTAssertEqual(vm.selectedImages.map(\.fileName), ["shot.png"])

        let second = try foreign.write { db in
            try TestDatabase.insertProjectTargetImage(db, projectID: pid, targetID: tid, fileName: "later.png", sha256: "l")
        }
        XCTAssertTrue(vm.refreshIfChanged())
        // Detaching the OLDER image keeps MAX(id); the count still moves.
        try foreign.write { db in
            try db.execute(sql: "DELETE FROM project_target_images WHERE target_id = ? AND id != ?", arguments: [tid, second])
        }
        XCTAssertTrue(vm.refreshIfChanged(), "a detach from the agent's process changes the fingerprint")
        XCTAssertEqual(vm.selectedImages.map(\.fileName), ["later.png"])

        vm.select(Int(other))
        XCTAssertEqual(vm.selectedImages.map(\.targetID), [other])
        vm.select(nil)
        XCTAssertEqual(vm.selectedImages, [])
    }

    /// PROJ-07: the drift check rides every poll tick, even on an unchanged
    /// board — a merge or fetch never touches the board's fingerprint.
    func testPollTickFiresOnAnUnchangedBoard() async throws {
        let vm = makeVM(project: 1)
        vm.load()
        let ticked = expectation(description: "a poll tick on an unchanged board")
        ticked.assertForOverFulfill = false
        vm.onPollTick = { ticked.fulfill() }
        vm.startPolling(every: .milliseconds(10))
        await fulfillment(of: [ticked], timeout: 5)
        vm.stopPolling()
    }

}

import GRDB
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerCore

/// The Desktop's reads of the multi-folder tables (00197) and the folder
/// columns it writes on its own rows: the no-CLI session insert and the
/// reviewer threads.
final class WorkbenchFolderQueriesTests: XCTestCase {
    private var db: DatabaseQueue!
    private var bench: Int64 = 0

    override func setUpWithError() throws {
        db = try TestDatabase.create()
        bench = try db.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: "/tmp/acme") }
    }

    @discardableResult
    private func addFolder(_ path: String, position: Int, removed: Bool = false) throws -> Int64 {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO workbench_folders (workbench_id, folder_path, position, added_by, name, removed_at)
                VALUES (?, ?, ?, 'owner', ?, ?)
                """, arguments: [bench, path, position, (path as NSString).lastPathComponent,
                                 removed ? "2026-11-18T00:00:00Z" : nil])
            return db.lastInsertedRowID
        }
    }

    private func homeID() throws -> Int64 {
        try XCTUnwrap(try db.read { try WorkbenchFolderQueries.homeFolderID($0, workbenchID: bench) })
    }

    // MARK: Folders

    func testFoldersInPositionOrder() throws {
        try addFolder("/tmp/site", position: 2)
        try addFolder("/tmp/old", position: 3, removed: true)
        try addFolder("/tmp/hub", position: 1)
        let live = try db.read { try WorkbenchFolderQueries.folders($0, workbenchID: bench, withRemoved: false) }
        XCTAssertEqual(live.map(\.name), ["acme", "hub", "site"])
        XCTAssertEqual(live.map(\.position), [0, 1, 2])
        XCTAssertEqual(live.first?.folderPath, "/tmp/acme")
        XCTAssertEqual(live.first?.addedBy, "owner")
        XCTAssertNil(live.first?.removedAt)

        let all = try db.read { try WorkbenchFolderQueries.folders($0, workbenchID: bench, withRemoved: true) }
        XCTAssertEqual(all.map(\.name), ["acme", "hub", "site", "old"])
        XCTAssertTrue(all[3].isRemoved)
    }

    func testAWorkbenchWithoutFoldersReadsEmpty() throws {
        let other = try db.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO projects (name, folder_path) VALUES ('bare', '/tmp/bare')")
            return db.lastInsertedRowID
        }
        let read = try db.read { try WorkbenchFolderQueries.benchFolders($0, workbenchID: other) }
        XCTAssertEqual(read, BenchFolders())
    }

    /// Home is the live folder at `projects.folder_path`, whatever its
    /// position (Go `db.HomeFolder`).
    func testHomeIsTheFolderAtTheProjectsPath() throws {
        let hub = try addFolder("/tmp/hub", position: 1)
        let first = try homeID()
        try db.write {
            try $0.execute(sql: "UPDATE workbench_folders SET position = 5 WHERE id = ?", arguments: [first])
            try $0.execute(sql: "UPDATE workbench_folders SET position = 0 WHERE id = ?", arguments: [hub])
        }
        let read = try db.read { try WorkbenchFolderQueries.benchFolders($0, workbenchID: bench) }
        XCTAssertEqual(read.homeID, first)
        XCTAssertEqual(read.home?.name, "acme")
        XCTAssertEqual(read.folder(nil)?.name, "acme", "nil names the home folder")
        XCTAssertEqual(read.folder(hub)?.name, "hub")
    }

    // MARK: Document paths (spec §6.11)

    func testDocPathShowsItsFolderOnlyWithSeveralFolders() throws {
        let one = try db.read { try WorkbenchFolderQueries.benchFolders($0, workbenchID: bench) }
        XCTAssertEqual(one.displayPath("docs/spec.md", folderID: nil), "docs/spec.md")

        let hub = try addFolder("/tmp/hub", position: 1)
        let two = try db.read { try WorkbenchFolderQueries.benchFolders($0, workbenchID: bench) }
        XCTAssertEqual(two.displayPath("docs/spec.md", folderID: nil), "acme/docs/spec.md", "an old ask resolves in home")
        XCTAssertEqual(two.displayPath("docs/spec.md", folderID: hub), "hub/docs/spec.md")
        XCTAssertEqual(two.displayPath("docs/spec.md", folderID: 999), "docs/spec.md", "an unknown folder shows the path alone")
        XCTAssertEqual(BenchFolders().displayPath("a.md", folderID: nil), "a.md")
    }

    // MARK: The Desktop's no-CLI session insert

    func testNoCLIStartUsesTheHomeFolder() throws {
        try addFolder("/tmp/hub", position: 1)
        let row = try db.write {
            try TerminalSessionQueries.create($0, .init(projectID: self.bench, kind: .shell, title: "sh", folderPath: "/tmp/acme"))
        }
        XCTAssertEqual(row.workbenchFolderID, try homeID())
        XCTAssertNil(row.parentSessionID)

        let standalone = try db.write {
            try TerminalSessionQueries.create($0, .init(projectID: nil, kind: .shell, title: "sh", folderPath: "/tmp"))
        }
        XCTAssertNil(standalone.workbenchFolderID, "a standalone terminal has no folder")
    }

    func testAGivenFolderIsKept() throws {
        let hub = try addFolder("/tmp/hub", position: 1)
        let row = try db.write {
            try TerminalSessionQueries.create($0, .init(projectID: self.bench, kind: .shell, title: "sh",
                                                        folderPath: "/tmp/hub", workbenchFolderID: hub))
        }
        XCTAssertEqual(row.workbenchFolderID, hub)
    }

    func testTargetReadsItsFolder() throws {
        let hub = try addFolder("/tmp/hub", position: 1)
        let target = try db.write { try TestDatabase.insertWorkbenchTarget($0, projectID: self.bench) }
        try db.write {
            try $0.execute(sql: "UPDATE targets SET workbench_folder_id = ? WHERE id = ?", arguments: [hub, target])
        }
        let read = try XCTUnwrap(try db.read { try Target.fetchOne($0, sql: "SELECT * FROM targets WHERE id = ?", arguments: [target]) })
        XCTAssertEqual(read.workbenchFolderID, hub)
        let plain = try db.write { try TestDatabase.insertWorkbenchTarget($0, projectID: self.bench) }
        XCTAssertNil(try db.read { try Target.fetchOne($0, sql: "SELECT * FROM targets WHERE id = ?", arguments: [plain]) }?
            .workbenchFolderID, "NULL is the home folder")
    }

    // MARK: Session messages (read-only)

    private func session() throws -> Int64 {
        try db.write {
            try TerminalSessionQueries.create($0, .init(projectID: self.bench, kind: .shell, title: "sh", folderPath: "/tmp/acme")).id
        }
    }

    @discardableResult
    private func message(from: Int64?, to: Int64?, state: String, reason: String = "", cleared: Bool = false) throws -> Int64 {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO session_messages (workbench_id, from_session_id, to_session_id, kind, text, state, reason,
                                              prompt_cleared_at)
                VALUES (?, ?, ?, 'message', 'look at hub', ?, ?, ?)
                """, arguments: [bench, from, to, state, reason, cleared ? "2026-11-18T00:00:00Z" : nil])
            return db.lastInsertedRowID
        }
    }

    func testWaitingInPromptIsTheUnclearedTypedRows() throws {
        let (a, b, c, d) = (try session(), try session(), try session(), try session())
        try message(from: a, to: b, state: "delivered", reason: SessionMessage.typedNotSubmitted)
        try message(from: a, to: c, state: "delivered", reason: SessionMessage.typedNotSubmitted, cleared: true)
        try message(from: a, to: d, state: "delivered")
        try message(from: b, to: a, state: "queued")
        let waiting = try db.read { try SessionMessageQueries.waitingInPrompt($0, sessionIDs: [a, b, c, d]) }
        XCTAssertEqual(waiting, [b])
        XCTAssertEqual(try db.read { try SessionMessageQueries.waitingInPrompt($0, sessionIDs: [a, c]) }, [])
        XCTAssertEqual(try db.read { try SessionMessageQueries.waitingInPrompt($0, sessionIDs: []) }, [])
    }

    func testQueuedAreTheSendersWaitingRows() throws {
        let (a, b) = (try session(), try session())
        let first = try message(from: a, to: b, state: "queued")
        try message(from: a, to: b, state: "delivered")
        let second = try message(from: a, to: b, state: "queued")
        try message(from: b, to: a, state: "queued")
        let queued = try db.read { try SessionMessageQueries.queued($0, fromSessionID: a) }
        XCTAssertEqual(queued.map(\.id), [first, second])
        XCTAssertEqual(queued.first?.text, "look at hub")
        XCTAssertEqual(queued.first?.toSessionID, b)
        XCTAssertEqual(queued.first?.kind, "message")
        XCTAssertNil(queued.first?.promptClearedAt)
    }

    // MARK: Reviewer threads per folder (#2003, parked from Task 5)

    func testReviewerThreadsAreKeyedByTheSessionsFolder() throws {
        let hub = try addFolder("/tmp/hub", position: 1)
        let home = try db.write { try ReviewerThreadQueries.ensure($0, projectID: self.bench, folderID: nil, branch: "feat/a") }
        let homeFolder = try homeID()
        let homeByID = try db.write {
            try ReviewerThreadQueries.ensure($0, projectID: self.bench, folderID: homeFolder, branch: "feat/a")
        }
        let inHub = try db.write { try ReviewerThreadQueries.ensure($0, projectID: self.bench, folderID: hub, branch: "feat/a") }
        XCTAssertEqual(home, homeByID, "nil is the home folder's thread")
        XCTAssertNotEqual(home, inHub, "the same branch in another folder is another thread")
        XCTAssertEqual(try db.read { try ReviewerThreadQueries.conversationID($0, projectID: self.bench, folderID: hub, branch: "feat/a") },
                       inHub)
        let context = try XCTUnwrap(try db.read { try ChatConversationQueries.fetchByID($0, id: inHub) })
        XCTAssertEqual(context.contextID, "\(bench):f\(hub):feat/a")
    }
}

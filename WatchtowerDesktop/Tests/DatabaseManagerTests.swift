import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerTestSupport

final class DatabaseManagerTests: XCTestCase {
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

    // MARK: - wipeLLMData

    func testWipeLLMDataPreservesUserCreatedTargets() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertTarget(db, text: "Manual todo", sourceType: "manual")
            try TestDatabase.insertTarget(db, text: "Jira-linked", sourceType: "jira")
            try TestDatabase.insertTarget(db, text: "From digest", sourceType: "digest")
            try TestDatabase.insertTarget(db, text: "Extracted", sourceType: "extract")
            try TestDatabase.insertInboxItem(db)
        }

        try dbManager.wipeLLMData()

        let remainingTexts: [String] = try dbManager.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT text FROM targets ORDER BY text")
        }
        XCTAssertEqual(remainingTexts, ["Jira-linked", "Manual todo"])

        let remainingCount: Int = try dbManager.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM targets") ?? -1
        }
        XCTAssertEqual(remainingCount, 2)

        let inboxCount: Int = try dbManager.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_items") ?? -1
        }
        XCTAssertEqual(inboxCount, 0)
    }

    /// Project targets are source_type='chat', which "Wipe LLM data" deletes.
    /// A project board is durable work state (PROJ-02: only a project delete
    /// removes it), so the wipe must spare it — and its comments, which would
    /// cascade with it.
    func testWipeLLMDataPreservesProjectTargets() throws {
        try dbManager.dbPool.write { db in
            try db.execute(sql: "INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/acme')")
            let projectID = db.lastInsertedRowID
            let boardTarget = try TestDatabase.insertTarget(db, text: "Board task", sourceType: "chat")
            try db.execute(sql: "UPDATE targets SET project_id = ? WHERE id = ?", arguments: [projectID, boardTarget])
            try db.execute(
                sql: "INSERT INTO project_comments (project_id, target_id, author, body) VALUES (?, ?, 'agent', 'q')",
                arguments: [projectID, boardTarget]
            )
            try TestDatabase.insertTarget(db, text: "Chat suggestion", sourceType: "chat")
        }

        try dbManager.wipeLLMData()

        let texts: [String] = try dbManager.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT text FROM targets ORDER BY text")
        }
        XCTAssertEqual(texts, ["Board task"])
        let comments: Int = try dbManager.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project_comments") ?? -1
        }
        XCTAssertEqual(comments, 1)
    }
}

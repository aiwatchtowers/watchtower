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

    // MARK: - init(path:) busy wait

    /// The real `init(path:)` waits for another process's write lock: the
    /// 5 s wait now comes only from `DBLockInstrumentation.install` (the
    /// `PRAGMA busy_timeout = 5000` it replaced is gone), so without it this
    /// write would fail at once with SQLITE_BUSY.
    func testInitPathWriterWaitsForAnotherConnectionsWriteLock() throws {
        let (seedPool, path) = try TestDatabase.createPool()
        try seedPool.close()
        defer { TestDatabase.cleanup(path: path) }
        let manager = try DatabaseManager(path: path)

        var holderConfig = Configuration()
        holderConfig.allowsUnsafeTransactions = true
        let holder = try DatabaseQueue(path: path, configuration: holderConfig)
        try holder.writeWithoutTransaction { try $0.execute(sql: "BEGIN IMMEDIATE") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            try? holder.writeWithoutTransaction { try $0.execute(sql: "ROLLBACK") }
        }

        let start = Date()
        try manager.dbPool.write { try $0.execute(sql: "INSERT INTO channels (id, name, type) VALUES ('C1', 'general', 'public')") }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.25, "the write waited for the holder")

        // The wait is above the default 200 ms threshold: the tx line lands
        // next to the DB unless the environment overrides the threshold.
        guard ProcessInfo.processInfo.environment["WATCHTOWER_DBLOCK_THRESHOLD_MS"] == nil else { return }
        let sink = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("dblock.jsonl")
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: sink), Date() < deadline { usleep(10_000) }
        let text = try String(contentsOfFile: sink, encoding: .utf8)
        XCTAssertTrue(text.contains("\"kind\":\"tx\""), text)
        XCTAssertTrue(text.contains("\"site\":\"desktop:channels\""), text)
    }
}

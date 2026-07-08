import XCTest
import GRDB
@testable import WatchtowerDesktop

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
}

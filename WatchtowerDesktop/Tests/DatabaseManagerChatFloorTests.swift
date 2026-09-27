import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// The Desktop no longer creates chat tables; it refuses a DB that goose
/// migration 00076 has not reached (chat_turn_steps is created only there).
final class DatabaseManagerChatFloorTests: XCTestCase {
    func testOpensAMigratedDatabase() throws {
        let path = try makeDB(dropping: nil)
        defer { TestDatabase.cleanup(path: path) }
        XCTAssertNoThrow(try DatabaseManager(path: path))
    }

    func testRefusesADatabaseWithoutTheChatCoreMigration() throws {
        let path = try makeDB(dropping: "chat_turn_steps")
        defer { TestDatabase.cleanup(path: path) }
        XCTAssertThrowsError(try DatabaseManager(path: path)) { error in
            guard case WatchtowerDatabaseError.missingTable(let table) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(table, "chat_turn_steps")
        }
    }

    private func makeDB(dropping table: String?) throws -> String {
        let (pool, path) = try TestDatabase.createPool()
        if let table {
            try pool.write { try $0.execute(sql: "DROP TABLE \(table)") }
        }
        try pool.close()
        return path
    }
}

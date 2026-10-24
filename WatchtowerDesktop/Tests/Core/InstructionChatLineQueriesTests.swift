import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

final class InstructionChatLineQueriesTests: XCTestCase {
    func testForMessagesReturnsTheLinesOfThoseMessagesOnly() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO instruction_chat_lines (line, conversation_id, message_id, added_at) VALUES
                ('Answer short', 5, 11, '2026-10-24T08:00:00Z'),
                ('Use bullets', 5, 12, '2026-10-24T08:05:00Z'),
                ('Typed in Settings', NULL, NULL, '2026-10-24T08:06:00Z')
                """)
        }
        let found = try queue.read { try InstructionChatLineQueries.forMessages($0, ids: [11, 99]) }
        XCTAssertEqual(Array(found.keys), [11])
        XCTAssertEqual(found[11]?.line, "Answer short")
        XCTAssertEqual(found[11]?.conversationID, 5)
        XCTAssertEqual(found[11]?.addedAt, "2026-10-24T08:00:00Z")
    }

    func testNoIdsIsEmptyWithoutAQuery() throws {
        let queue = try TestDatabase.create()
        let found = try queue.read { try InstructionChatLineQueries.forMessages($0, ids: []) }
        XCTAssertTrue(found.isEmpty)
    }
}

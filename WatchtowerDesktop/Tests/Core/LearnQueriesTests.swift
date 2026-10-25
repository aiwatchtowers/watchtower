import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// `learn_seen` and the row-backed Learn signals.
final class LearnQueriesTests: XCTestCase {
    private var db: DatabaseQueue!
    private let now = Date(timeIntervalSince1970: 1_792_900_000) // 2026-10-25 UTC

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    func testSeenInsertIgnoreAndShowAgain() throws {
        try db.write { d in
            try LearnQueries.markSeen(d, ids: ["a", "b"], how: .inUse, now: self.now)
            // A second write keeps the first row.
            try LearnQueries.markSeen(d, ids: ["a"], how: .gotIt, now: self.now + 60)
        }
        XCTAssertEqual(try db.read(LearnQueries.fetchSeen), ["a": .inUse, "b": .inUse])
        let seenAt = try db.read { try String.fetchOne($0, sql: "SELECT seen_at FROM learn_seen WHERE item_id = 'a'") }
        XCTAssertEqual(seenAt, "2026-10-25T03:46:40Z")
        try db.write { try LearnQueries.showAgain($0, id: "a") }
        XCTAssertEqual(try db.read(LearnQueries.fetchSeen), ["b": .inUse])
    }

    func testNoSignalsOnAnEmptyDatabase() throws {
        XCTAssertEqual(try db.read(LearnQueries.rowSignals), [])
    }

    func testRowSignals() throws {
        try db.write { d in
            try d.execute(sql: "INSERT INTO meeting_transcripts (title, transcript_text) VALUES ('Sync', '')")
            try d.execute(sql: "INSERT INTO chat_conversations (created_at, updated_at) VALUES (1, 1)")
            try d.execute(sql: """
                INSERT INTO chat_messages (conversation_id, role, text, created_at)
                VALUES (last_insert_rowid(), 'assistant', 'hi', 1)
                """)
            try d.execute(sql: "INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/acme')")
            try d.execute(sql: """
                INSERT INTO reaction_commands (account_id, channel_id, message_ts, emoji)
                VALUES (1, 'C1', '1.0', 'ticket')
                """)
            try d.execute(sql: """
                INSERT INTO automations (slug, scope, path, origin, builtin_id)
                VALUES ('brief', 'personal', 'builtin:brief', 'builtin', 'brief')
                """)
        }
        // An assistant message and a built-in automation do not count.
        XCTAssertEqual(try db.read(LearnQueries.rowSignals), [.meetingRecorded, .workbenchBound, .reactionUsed])

        try db.write { d in
            try d.execute(sql: """
                INSERT INTO chat_messages (conversation_id, role, text, created_at)
                SELECT id, 'user', 'hello', 2 FROM chat_conversations
                """)
            try d.execute(sql: "INSERT INTO automations (slug, scope, path) VALUES ('mine', 'personal', '/tmp/mine.md')")
        }
        XCTAssertEqual(
            try db.read(LearnQueries.rowSignals),
            [.meetingRecorded, .workbenchBound, .reactionUsed, .chatUsed, .automationCreated])
    }
}

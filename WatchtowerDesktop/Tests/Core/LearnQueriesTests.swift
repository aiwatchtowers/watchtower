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
        // An assistant message, a pending reaction and a built-in automation do not count.
        XCTAssertEqual(try db.read(LearnQueries.rowSignals), [.meetingRecorded, .workbenchBound])

        try db.write { d in
            try d.execute(sql: """
                INSERT INTO chat_messages (conversation_id, role, text, created_at)
                SELECT id, 'user', 'hello', 2 FROM chat_conversations
                """)
            try d.execute(sql: "INSERT INTO automations (slug, scope, path) VALUES ('mine', 'personal', '/tmp/mine.md')")
            try d.execute(sql: "UPDATE reaction_commands SET status = 'dispatched'")
        }
        XCTAssertEqual(
            try db.read(LearnQueries.rowSignals),
            [.meetingRecorded, .workbenchBound, .reactionUsed, .chatUsed, .automationCreated])
    }

    /// The seed records reactions older than the feature as `skipped`; only
    /// a dispatched one means the owner used it.
    func testReactionSignalSkipsSeededRows() throws {
        try db.write { d in
            try d.execute(sql: """
                INSERT INTO reaction_commands (account_id, channel_id, message_ts, emoji, status, error)
                VALUES (1, 'C1', '1.0', 'ticket', 'skipped', 'seeded as pre-existing reaction history')
                """)
        }
        XCTAssertEqual(try db.read(LearnQueries.rowSignals), [])
        try db.write { d in
            try d.execute(sql: """
                INSERT INTO reaction_commands (account_id, channel_id, message_ts, emoji, status)
                VALUES (1, 'C1', '2.0', 'ticket', 'dispatched')
                """)
        }
        XCTAssertEqual(try db.read(LearnQueries.rowSignals), [.reactionUsed])
    }

    /// An embedded chat (a `context_type`) is not the AI Chat.
    func testChatSignalOnlyFromTheMainChat() throws {
        try db.write { d in
            try d.execute(sql: """
                INSERT INTO chat_conversations (created_at, updated_at, context_type, context_id)
                VALUES (1, 1, 'automation_editor', '7')
                """)
            try d.execute(sql: """
                INSERT INTO chat_messages (conversation_id, role, text, created_at)
                VALUES (last_insert_rowid(), 'user', 'hello', 1)
                """)
        }
        XCTAssertEqual(try db.read(LearnQueries.rowSignals), [])
        try db.write { d in
            try d.execute(sql: "INSERT INTO chat_conversations (created_at, updated_at) VALUES (2, 2)")
            try d.execute(sql: """
                INSERT INTO chat_messages (conversation_id, role, text, created_at)
                VALUES (last_insert_rowid(), 'user', 'hello', 2)
                """)
        }
        XCTAssertEqual(try db.read(LearnQueries.rowSignals), [.chatUsed])
    }

    /// Confluence counts while a space syncs; a turned-off space does not.
    func testConfluenceSignal() throws {
        try db.write { d in
            try d.execute(sql: "INSERT INTO jira_accounts (id, status) VALUES (10, 'ok')")
            try TestDatabase.insertExtSource(d, jiraAccountID: 10, containerKey: "ENG")
            try d.execute(sql: "UPDATE ext_sources SET enabled = 0")
        }
        XCTAssertEqual(try db.read(LearnQueries.rowSignals), [])
        try db.write { try $0.execute(sql: "UPDATE ext_sources SET enabled = 1") }
        XCTAssertEqual(try db.read(LearnQueries.rowSignals), [.confluenceConnected])
    }
}

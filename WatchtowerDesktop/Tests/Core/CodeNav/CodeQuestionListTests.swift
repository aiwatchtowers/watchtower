import GRDB
import WatchtowerCore
import WatchtowerTestSupport
import XCTest

/// The Questions tab's list (spec 2026-10-02 §9.4): one workbench's code
/// questions, newest first, with the first question and the `path:line`
/// each was asked from; Delete removes a conversation and its messages.
final class CodeQuestionListTests: XCTestCase {
    private func conversation(
        _ db: Database,
        contextID: String,
        createdAt: Double,
        contextType: String? = CodeQuestionList.contextType,
        messages: [(role: String, text: String)] = []
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
            VALUES ('t', ?, ?, ?, ?)
            """, arguments: [contextType, contextID, createdAt, createdAt])
        let id = db.lastInsertedRowID
        for (offset, message) in messages.enumerated() {
            try db.execute(sql: """
                INSERT INTO chat_messages (conversation_id, role, text, created_at) VALUES (?, ?, ?, ?)
                """, arguments: [id, message.role, message.text, createdAt + Double(offset)])
        }
        return id
    }

    /// Workbench 1's rows only (never 10's or 11's, whose ids start with
    /// "1"), newest first, the first owner message as the question.
    func testListsOneWorkbenchNewestFirstWithItsOrigin() throws {
        let queue = try TestDatabase.create()
        let (older, newer, noFile) = try queue.write { db in
            let older = try self.conversation(db, contextID: "1:Sources/App.swift:12", createdAt: 100, messages: [
                ("user", "Explain this."), ("assistant", "It loads."), ("user", "And then?")
            ])
            let newer = try self.conversation(db, contextID: "1:a:b.swift:3", createdAt: 300, messages: [("user", "Why a colon?")])
            let noFile = try self.conversation(db, contextID: "1::0", createdAt: 200)
            _ = try self.conversation(db, contextID: "10:Sources/App.swift:1", createdAt: 400, messages: [("user", "other")])
            _ = try self.conversation(db, contextID: "11:x:1", createdAt: 500)
            _ = try self.conversation(db, contextID: "1:Sources/App.swift:1", createdAt: 600, contextType: "track")
            _ = try self.conversation(db, contextID: "1:Sources/App.swift:1", createdAt: 700, contextType: nil)
            return (older, newer, noFile)
        }
        let items = try queue.read { try CodeQuestionList.fetch($0, workbenchID: 1) }
        XCTAssertEqual(items.map(\.conversationID), [newer, noFile, older])
        XCTAssertEqual(items[0].path, "a:b.swift", "the line is after the last colon")
        XCTAssertEqual(items[0].line, 3)
        XCTAssertEqual(items[0].originLabel, "a:b.swift:3")
        XCTAssertNil(items[1].firstQuestion, "nothing sent yet")
        XCTAssertNil(items[1].originLabel, "asked with no file open (Open Quickly)")
        XCTAssertEqual(items[1].origin, CodeQuestionOrigin(path: "", line: 0, selection: nil))
        XCTAssertEqual(items[2].firstQuestion, "Explain this.")
        XCTAssertEqual(items[2].createdAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try queue.read { try CodeQuestionList.fetch($0, workbenchID: 10) }.count, 1)
    }

    func testContextIDParsing() {
        XCTAssertEqual(CodeQuestionList.origin(contextID: "7:Sources/App.swift:12", workbenchID: 7)?.path, "Sources/App.swift")
        XCTAssertEqual(CodeQuestionList.origin(contextID: "7::0", workbenchID: 7), CodeQuestionOrigin(path: "", line: 0, selection: nil))
        XCTAssertNil(CodeQuestionList.origin(contextID: "70:a:1", workbenchID: 7), "another workbench")
        XCTAssertNil(CodeQuestionList.origin(contextID: "7:a", workbenchID: 7), "no line")
        XCTAssertNil(CodeQuestionList.origin(contextID: "7:a:x", workbenchID: 7), "not a line number")
    }

    /// Delete removes the conversation and its messages (FTS included), and
    /// touches only code questions.
    func testDeleteRemovesTheConversationAndItsMessages() throws {
        let queue = try TestDatabase.create()
        let (question, mainChat) = try queue.write { db in
            let question = try self.conversation(db, contextID: "1:a.swift:1", createdAt: 1, messages: [
                ("user", "zebraquestion"), ("assistant", "zebraanswer")
            ])
            let mainChat = try self.conversation(db, contextID: "", createdAt: 2, contextType: nil, messages: [("user", "keep")])
            return (question, mainChat)
        }
        XCTAssertTrue(try queue.write { try CodeQuestionList.delete($0, conversationID: question) })
        XCTAssertFalse(try queue.write { try CodeQuestionList.delete($0, conversationID: mainChat) }, "not a code question")
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_conversations"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ?",
                                            arguments: [question]), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_fts WHERE chat_fts MATCH 'zebraanswer'"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_messages"), 1)
        }
    }
}

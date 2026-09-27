import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatArtifactQueriesTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private var conversationID: Int64 = 0

    override func setUpWithError() throws {
        dbQueue = try TestDatabase.create()
        conversationID = try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 0, 0)")
            return db.lastInsertedRowID
        }
    }

    private func insertAssistantMessage() throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO chat_messages (conversation_id, role, text, turn_id, created_at) VALUES (?, 'assistant', '', '', 0)",
                arguments: [conversationID])
            return db.lastInsertedRowID
        }
    }

    private func doc(_ content: String, key: String = "q3", meta: [String: String] = [:]) -> ArtifactDraft {
        ArtifactDraft(key: key, kind: "document", title: "Q3", meta: meta, content: content, isComplete: true)
    }

    private func save(_ draft: ArtifactDraft, message: Int64, edited: Bool = false) throws -> ChatArtifact {
        try dbQueue.write {
            try ChatArtifactQueries.saveVersion($0, conversationID: conversationID, messageID: message, draft: draft, edited: edited)
        }
    }

    func testFirstSaveIsVersionOneWithMeta() throws {
        let m1 = try insertAssistantMessage()
        let saved = try save(doc("a", meta: ["language": "go"]), message: m1)
        XCTAssertEqual(saved.version, 1)
        XCTAssertEqual(saved.meta, ["language": "go"])
        XCTAssertFalse(saved.edited)
        XCTAssertEqual(saved.asDraft, doc("a", meta: ["language": "go"]))
    }

    func testResaveFromSameMessageOverwritesInPlace() throws {
        let m1 = try insertAssistantMessage()
        _ = try save(doc("a"), message: m1)
        let again = try save(doc("b"), message: m1)
        XCTAssertEqual(again.version, 1)
        let all = try dbQueue.read { try ChatArtifactQueries.versions($0, conversationID: conversationID, key: "q3") }
        XCTAssertEqual(all.map(\.content), ["b"])
    }

    func testLaterMessageSameKeyIsNewVersion() throws {
        let m1 = try insertAssistantMessage()
        let m2 = try insertAssistantMessage()
        _ = try save(doc("a"), message: m1)
        _ = try save(doc("b"), message: m2)
        let latest = try dbQueue.read { try ChatArtifactQueries.latest($0, conversationID: conversationID, key: "q3") }
        XCTAssertEqual(latest?.version, 2)
        XCTAssertEqual(latest?.content, "b")
        let all = try dbQueue.read { try ChatArtifactQueries.versions($0, conversationID: conversationID, key: "q3") }
        XCTAssertEqual(all.map(\.version), [1, 2])
    }

    func testEditAlwaysInsertsEditedVersion() throws {
        let m1 = try insertAssistantMessage()
        _ = try save(doc("a"), message: m1)
        let edited = try save(doc("a, edited"), message: m1, edited: true)
        XCTAssertEqual(edited.version, 2)
        XCTAssertTrue(edited.edited)
        // A re-persist of the same message after an edit must not clobber the edit.
        let repersist = try save(doc("a"), message: m1)
        XCTAssertEqual(repersist.version, 3)
    }

    func testKeysVersionIndependently() throws {
        let m1 = try insertAssistantMessage()
        _ = try save(doc("a"), message: m1)
        XCTAssertEqual(try save(doc("x", key: "other"), message: m1).version, 1)
    }

    func testPersistArtifactsFromFinalText() throws {
        let m1 = try insertAssistantMessage()
        let text = "Intro\n:::artifact key=\"q3\" kind=\"document\" title=\"Q3\"\nbody\n:::\n:::artifact key=\"t\" kind=\"table\" title=\"T\"\na,b"
        let saved = try dbQueue.write {
            try ChatArtifactQueries.persistArtifacts($0, conversationID: conversationID, messageID: m1, text: text)
        }
        XCTAssertEqual(saved.map(\.artifactKey), ["q3", "t"])
        XCTAssertEqual(saved.last?.content, "a,b", "an unterminated block at turn end is kept")
        let byMessage = try dbQueue.read { try ChatArtifactQueries.versionsByMessage($0, messageIDs: [m1]) }
        XCTAssertEqual(byMessage[m1], ["q3": 1, "t": 1])
    }

    func testDeletingMessageCascades() throws {
        let m1 = try insertAssistantMessage()
        _ = try save(doc("a"), message: m1)
        try dbQueue.write { try $0.execute(sql: "DELETE FROM chat_messages WHERE id = ?", arguments: [m1]) }
        XCTAssertNil(try dbQueue.read { try ChatArtifactQueries.latest($0, conversationID: conversationID, key: "q3") })
    }
}

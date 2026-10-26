import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

@MainActor
final class ArtifactKnowledgeTests: XCTestCase {
    func testStateForKeptAndShownVersions() {
        typealias State = ArtifactKnowledgeState
        XCTAssertEqual(State.for(kind: "document", shownVersion: 2, keptVersion: nil), .add)
        XCTAssertEqual(State.for(kind: "table", shownVersion: 2, keptVersion: 2), .remove)
        XCTAssertEqual(State.for(kind: "code", shownVersion: 3, keptVersion: 1), .update)
        XCTAssertEqual(State.for(kind: "html", shownVersion: 1, keptVersion: nil), .add)
        // An older version shown while a newer one is kept: it is not the kept
        // version, so no control (neither Update nor Remove) is offered.
        XCTAssertNil(State.for(kind: "document", shownVersion: 1, keptVersion: 2))
    }

    func testDraftKindsGetNoControl() {
        for kind in ["email", "slack", "event"] {
            XCTAssertNil(ArtifactKnowledgeState.for(kind: kind, shownVersion: 1, keptVersion: nil), kind)
        }
    }

    func testTitles() {
        XCTAssertEqual(ArtifactKnowledgeState.add.title, "Add to Knowledge")
        XCTAssertEqual(ArtifactKnowledgeState.update.title, "Update in Knowledge")
        XCTAssertEqual(ArtifactKnowledgeState.remove.title, "Remove from Knowledge")
    }

    func testPanelModelKeepsUpdatesAndRemoves() async throws {
        let dbQueue = try TestDatabase.create()
        let (conversation, message) = try await dbQueue.write { db -> (Int64, Int64) in
            try db.execute(sql: "INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 0, 0)")
            let conversation = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO chat_messages (conversation_id, role, text, turn_id, created_at) VALUES (?, 'assistant', '', '', 0)",
                           arguments: [conversation])
            let message = db.lastInsertedRowID
            let draft = ArtifactDraft(key: "q3", kind: "document", title: "Q3", meta: [:], content: "one", isComplete: true)
            try ChatArtifactQueries.saveVersion(db, conversationID: conversation, messageID: message, draft: draft, edited: false)
            return (conversation, message)
        }
        let model = ArtifactPanelModel(db: dbQueue, conversationID: conversation, key: "q3")
        var changes = 0
        model.onKnowledgeChanged = { changes += 1 }
        XCTAssertEqual(model.knowledgeState, .add)

        await model.toggleKnowledge()
        XCTAssertEqual(model.keptVersion, 1)
        XCTAssertEqual(model.knowledgeState, .remove)

        // A newer version appears: the button offers Update.
        try await dbQueue.write { db in
            let draft = ArtifactDraft(key: "q3", kind: "document", title: "Q3", meta: [:], content: "two", isComplete: true)
            try ChatArtifactQueries.saveVersion(db, conversationID: conversation, messageID: message, draft: draft, edited: true)
        }
        model.reload()
        XCTAssertEqual(model.knowledgeState, .update)
        await model.toggleKnowledge()
        XCTAssertEqual(model.keptVersion, 2)
        XCTAssertEqual(model.knowledgeState, .remove)

        await model.toggleKnowledge()
        XCTAssertNil(model.keptVersion)
        XCTAssertEqual(model.knowledgeState, .add)
        XCTAssertEqual(changes, 3)
        XCTAssertNil(model.errorMessage)
    }

    func testRemoveFromUpdateStateDropsThePin() async throws {
        let dbQueue = try TestDatabase.create()
        let conversation = try await dbQueue.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 0, 0)")
            let conversation = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO chat_messages (conversation_id, role, text, turn_id, created_at) VALUES (?, 'assistant', '', '', 0)",
                           arguments: [conversation])
            let message = db.lastInsertedRowID
            for (content, edited) in [("one", false), ("two", true)] {
                let draft = ArtifactDraft(key: "q3", kind: "document", title: "Q3", meta: [:], content: content, isComplete: true)
                try ChatArtifactQueries.saveVersion(db, conversationID: conversation, messageID: message, draft: draft, edited: edited)
            }
            try ChatArtifactQueries.keep(db, conversationID: conversation, artifactKey: "q3", version: 1)
            return conversation
        }
        let model = ArtifactPanelModel(db: dbQueue, conversationID: conversation, key: "q3")
        var changes = 0
        model.onKnowledgeChanged = { changes += 1 }
        XCTAssertEqual(model.knowledgeState, .update)
        await model.removeKnowledge()
        XCTAssertNil(model.keptVersion)
        XCTAssertEqual(model.knowledgeState, .add)
        XCTAssertEqual(changes, 1)
    }

    func testEmailArtifactHasNoControlInPanelModel() async throws {
        let dbQueue = try TestDatabase.create()
        let conversation = try await dbQueue.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 0, 0)")
            let conversation = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO chat_messages (conversation_id, role, text, turn_id, created_at) VALUES (?, 'assistant', '', '', 0)",
                           arguments: [conversation])
            let draft = ArtifactDraft(key: "mail", kind: "email", title: "Mail", meta: [:], content: "hi", isComplete: true)
            try ChatArtifactQueries.saveVersion(db, conversationID: conversation, messageID: db.lastInsertedRowID, draft: draft, edited: false)
            return conversation
        }
        let model = ArtifactPanelModel(db: dbQueue, conversationID: conversation, key: "mail")
        XCTAssertNil(model.knowledgeState)
    }
}

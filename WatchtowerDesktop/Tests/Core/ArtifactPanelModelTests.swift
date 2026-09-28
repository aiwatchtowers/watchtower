import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

@MainActor
final class ArtifactPanelModelTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private var conversationID: Int64 = 0
    private var m1: Int64 = 0
    private var m2: Int64 = 0

    override func setUp() async throws {
        dbQueue = try TestDatabase.create()
        (conversationID, m1, m2) = try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 0, 0)")
            let conversation = db.lastInsertedRowID
            var ids: [Int64] = []
            for _ in 0..<2 {
                try db.execute(sql: "INSERT INTO chat_messages (conversation_id, role, text, turn_id, created_at) VALUES (?, 'assistant', '', '', 0)",
                               arguments: [conversation])
                ids.append(db.lastInsertedRowID)
            }
            return (conversation, ids[0], ids[1])
        }
    }

    private func doc(_ content: String, complete: Bool = true) -> ArtifactDraft {
        ArtifactDraft(key: "q3", kind: "document", title: "Q3", meta: [:], content: content, isComplete: complete)
    }

    private func store(_ content: String, message: Int64) throws {
        _ = try dbQueue.write {
            try ChatArtifactQueries.saveVersion($0, conversationID: conversationID, messageID: message, draft: doc(content), edited: false)
        }
    }

    func testShowsLatestAndSwitchesVersions() throws {
        try store("v1", message: m1)
        try store("v2", message: m2)
        let model = ArtifactPanelModel(db: dbQueue, conversationID: conversationID, key: "q3")
        XCTAssertEqual(model.versions.map(\.version), [1, 2])
        XCTAssertEqual(model.displayed?.content, "v2")
        model.selectedVersion = 1
        XCTAssertEqual(model.displayed?.content, "v1")
    }

    func testLiveDraftWinsWhileStreamingThenStoredVersionAfter() throws {
        let model = ArtifactPanelModel(db: dbQueue, conversationID: conversationID, key: "q3")
        XCTAssertNil(model.displayed)
        model.applyStreaming([doc("partial", complete: false)])
        XCTAssertEqual(model.displayed?.content, "partial")
        model.applyStreaming([ArtifactDraft(key: "other", kind: "document", title: "O", meta: [:], content: "x", isComplete: false)])
        XCTAssertEqual(model.displayed?.content, "partial", "another key's draft does not touch this panel")
        try store("final", message: m1)
        model.turnFinished()
        XCTAssertNil(model.liveDraft)
        XCTAssertEqual(model.displayed?.content, "final")
    }

    func testEditSavesNewEditedVersion() throws {
        try store("v1", message: m1)
        let model = ArtifactPanelModel(db: dbQueue, conversationID: conversationID, key: "q3")
        model.beginEdit()
        XCTAssertTrue(model.isEditing)
        XCTAssertEqual(model.editText, "v1")
        model.editText = "v1 edited"
        model.saveEdit()
        XCTAssertFalse(model.isEditing)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.versions.map(\.version), [1, 2])
        XCTAssertEqual(model.versions.last?.edited, true)
        XCTAssertEqual(model.displayed?.content, "v1 edited")
    }

    func testUnchangedEditWritesNothingAndEditIsBlockedWhileWriting() throws {
        try store("v1", message: m1)
        let model = ArtifactPanelModel(db: dbQueue, conversationID: conversationID, key: "q3")
        model.beginEdit()
        model.saveEdit()
        XCTAssertEqual(model.versions.count, 1)
        model.applyStreaming([doc("streaming", complete: false)])
        model.beginEdit()
        XCTAssertFalse(model.isEditing)
    }

    func testFailedSaveKeepsEditorOpen() throws {
        try store("v1", message: m1)
        let model = ArtifactPanelModel(db: dbQueue, conversationID: conversationID, key: "q3")
        model.beginEdit()
        model.editText = "changed"
        try dbQueue.write { try $0.execute(sql: "DROP TABLE chat_artifacts") }
        model.saveEdit()
        XCTAssertTrue(model.isEditing, "UI state is cleared only after the write succeeds")
        XCTAssertEqual(model.editText, "changed")
        XCTAssertNotNil(model.errorMessage)
    }

    func testKeyToAutoOpen() {
        let writing = doc("x", complete: false)
        XCTAssertEqual(ArtifactPanelModel.keyToAutoOpen(drafts: [writing], currentKey: nil, dismissedKeys: []), "q3")
        XCTAssertNil(ArtifactPanelModel.keyToAutoOpen(drafts: [writing], currentKey: "q3", dismissedKeys: []))
        XCTAssertNil(ArtifactPanelModel.keyToAutoOpen(drafts: [writing], currentKey: nil, dismissedKeys: ["q3"]))
        XCTAssertNil(ArtifactPanelModel.keyToAutoOpen(drafts: [doc("x")], currentKey: nil, dismissedKeys: []))
    }
}

import XCTest
import GRDB
import SwiftUI
import ViewInspector
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Saved in place: a chat message behind a knowledge prefix becomes an active
/// registry item at once, and the chat shows it with Undo.
@MainActor
final class ChatKnowledgeCenterTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
    }

    override func tearDown() async throws {
        pool = nil
        TestDatabase.cleanup(path: path)
    }

    private func send(_ center: ChatKnowledgeCenter, _ text: String, message: Int64 = 11) async {
        center.ownerMessageSent(text: text, conversationID: 3, messageID: message)
        await center.waitForIdle()
    }

    private func ideas() throws -> [Idea] {
        try pool.read { try Idea.fetchAll($0, sql: "SELECT * FROM ideas ORDER BY id") }
    }

    func testPrefixedDecisionIsSavedWithAChatMention() async throws {
        let center = ChatKnowledgeCenter(dbPool: pool)
        await send(center, "Решили: ship on Thursdays\nfrom next week")
        let idea = try XCTUnwrap(try ideas().first)
        XCTAssertEqual(center.mark(for: 11), .saved(kind: "decision", ideaID: Int64(idea.id)))
        XCTAssertEqual(idea.kind, .decision)
        XCTAssertEqual(idea.status, .active)
        XCTAssertTrue(idea.chatBorn)
        XCTAssertEqual(idea.essence, "ship on Thursdays\nfrom next week")
        let refs = try await pool.read { try String.fetchAll($0, sql: "SELECT ref FROM idea_mentions WHERE source = 'chat'") }
        XCTAssertEqual(refs, ["chat:3:11"])
        XCTAssertEqual(center.runningWrites, 0, "a finished write leaves the task list")
    }

    func testFactIsSavedAsANote() async throws {
        let center = ChatKnowledgeCenter(dbPool: pool)
        await send(center, "fact: the staging db is reset nightly")
        let idea = try XCTUnwrap(try ideas().first)
        XCTAssertEqual(idea.kind, .note)
        XCTAssertEqual(center.mark(for: 11), .saved(kind: "note", ideaID: Int64(idea.id)))
    }

    func testEmptyBodyWritesNothing() async throws {
        let center = ChatKnowledgeCenter(dbPool: pool)
        await send(center, "decided:   ")
        XCTAssertEqual(center.mark(for: 11), .empty)
        XCTAssertEqual(try ideas(), [])
    }

    func testOrdinaryAndRememberMessagesAreIgnored() async throws {
        let center = ChatKnowledgeCenter(dbPool: pool)
        await send(center, "remember: answer short", message: 11)
        await send(center, "we decided: ship it", message: 12)
        XCTAssertNil(center.mark(for: 11))
        XCTAssertNil(center.mark(for: 12))
        XCTAssertEqual(try ideas(), [])
        // And the remember side leaves a knowledge prefix alone.
        XCTAssertNil(RememberCommand.parse("решили: ship it"))
    }

    func testUndoDeletesTheUntouchedItem() async throws {
        let center = ChatKnowledgeCenter(dbPool: pool)
        await send(center, "decided: ship on Thursdays")
        await center.undo(messageID: 11)
        XCTAssertEqual(center.mark(for: 11), .undone)
        XCTAssertEqual(try ideas(), [])
        let mentions = try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM idea_mentions") }
        XCTAssertEqual(mentions, 0)
    }

    func testUndoAfterAnEditKeepsTheItem() async throws {
        let center = ChatKnowledgeCenter(dbPool: pool)
        await send(center, "decided: ship on Thursdays")
        let id = try XCTUnwrap(try ideas().first).id
        try await pool.write { db in
            try db.execute(sql: "UPDATE ideas SET title = 'Ship on Fridays', updated_at = '2099-01-01T00:00:00Z' WHERE id = ?",
                           arguments: [id])
        }
        await center.undo(messageID: 11)
        XCTAssertEqual(center.mark(for: 11), .changed(ideaID: Int64(id)))
        XCTAssertEqual(try ideas().map(\.id), [id])
    }

    func testMarksAreRebuiltOnReopenAndUndoStillWorks() async throws {
        await send(ChatKnowledgeCenter(dbPool: pool), "факт: the release train leaves on Tuesdays")
        let id = try XCTUnwrap(try ideas().first).id

        let reopened = ChatKnowledgeCenter(dbPool: pool)
        await reopened.loadMark(conversationID: 3, messageID: 11)
        await reopened.loadMark(conversationID: 3, messageID: 12)
        XCTAssertEqual(reopened.mark(for: 11), .saved(kind: "note", ideaID: Int64(id)))
        XCTAssertNil(reopened.mark(for: 12))

        await reopened.undo(messageID: 11)
        XCTAssertEqual(reopened.mark(for: 11), .undone)
        XCTAssertEqual(try ideas(), [])
    }

    func testFailedWriteShowsItsReason() async throws {
        try await pool.write { try $0.execute(sql: "DROP TABLE idea_mentions") }
        let center = ChatKnowledgeCenter(dbPool: pool)
        await send(center, "decided: ship on Thursdays")
        guard case .failed? = center.mark(for: 11) else { return XCTFail("\(String(describing: center.mark(for: 11)))") }
        XCTAssertEqual(try ideas(), [], "the transaction rolled back")
    }

    /// The factory hands every stored owner message to both centers; each acts
    /// on its own prefix (the main chat and every embedded engine go here).
    func testFactoryFeedsTheKnowledgeCenter() async throws {
        let factory = EmbeddedChatEngineFactory()
        XCTAssertNil(factory.knowledgeCenter)
        factory.dbPool = pool
        let center = try XCTUnwrap(factory.knowledgeCenter)
        factory.ownerMessageStored(text: "decided: ship on Thursdays", conversationID: 3, messageID: 11)
        factory.ownerMessageStored(text: "remember: answer short", conversationID: 3, messageID: 12)
        await center.waitForIdle()
        guard case .saved? = center.mark(for: 11) else { return XCTFail("no mark") }
        XCTAssertNil(center.mark(for: 12))
        XCTAssertEqual(try ideas().count, 1)
    }

    private func engineSpec(contextType: String, conversationID: Int64) -> ChatSurfaceSpec {
        ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: contextType, contextID: "4", conversationID: conversationID),
            persistence: .database(conversationID: conversationID), toolAccess: .draftOnly,
            ownerInstructions: true, systemPrompt: { "" }, emptyHint: "")
    }

    /// A workbench code question never leaves its Questions tab (spec
    /// 2026-10-02 §9.4): a knowledge prefix typed there saves nothing, while
    /// another embedded chat (a target chat) still saves it.
    func testCodeQuestionEngineSavesNoKnowledge() async throws {
        let factory = EmbeddedChatEngineFactory()
        factory.dbPool = pool
        let center = try XCTUnwrap(factory.knowledgeCenter)

        let question = factory.center.engine(for: engineSpec(contextType: CodeQuestionList.contextType, conversationID: 3))
        question.onOwnerMessageStored?("decided: inline this helper", 3, 11)
        question.onOwnerMessageStored?("decided:", 3, 12)
        await center.waitForIdle()
        XCTAssertNil(center.mark(for: 11))
        XCTAssertNil(center.mark(for: 12), "not even the empty-body mark")
        XCTAssertEqual(try ideas(), [])

        let target = factory.center.engine(for: engineSpec(contextType: "target", conversationID: 5))
        target.onOwnerMessageStored?("decided: ship on Thursdays", 5, 21)
        await center.waitForIdle()
        guard case .saved? = center.mark(for: 21) else { return XCTFail("the target chat saved nothing") }
        XCTAssertEqual(try ideas().count, 1)
    }

    // MARK: - The mark's line

    private func line(_ mark: ChatKnowledgeMark, kind: String = "decision") -> ChatKnowledgeMarkLine {
        ChatKnowledgeMarkLine(mark: mark, prefixKind: kind, undo: {}, openInInbox: { _ in })
    }

    private func buttons(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Button.self).compactMap { try? $0.labelView().text().string() }
    }

    func testMarkLineWordsAndButtons() throws {
        XCTAssertEqual(line(.saved(kind: "decision", ideaID: 1)).label, "Saved as a decision")
        XCTAssertEqual(line(.saved(kind: "note", ideaID: 1)).label, "Saved as a fact")
        XCTAssertEqual(try buttons(line(.saved(kind: "decision", ideaID: 1))), ["Undo", "Open in Inbox"])
        XCTAssertEqual(line(.empty).label, "Nothing to save — write the decision after the colon")
        XCTAssertEqual(line(.empty, kind: "note").label, "Nothing to save — write the fact after the colon")
        XCTAssertEqual(try buttons(line(.empty)), [])
        XCTAssertEqual(line(.changed(ideaID: 1)).label, "Changed since — opened in Inbox")
        XCTAssertEqual(try buttons(line(.changed(ideaID: 1))), ["Open in Inbox"])
        XCTAssertEqual(try buttons(line(.undone)), [])
        XCTAssertEqual(line(.failed("db locked")).label, "Couldn't save this: db locked")
    }
}

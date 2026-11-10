import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Which embedded chats save a knowledge prefix: a spec review Discuss thread
/// and a code question stay out of the ideas registry (spec 2026-11-08 §3,
/// like Go's `ListChatTurnsForIdeas` filter); other chats save it.
@MainActor
final class EmbeddedChatWiringTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
    }

    override func tearDown() async throws {
        pool = nil
        TestDatabase.cleanup(path: path)
    }

    func testSavesKnowledgeByContext() {
        XCTAssertFalse(EmbeddedChatEngineFactory.savesKnowledge(contextType: SpecReviewThreadKey.contextType))
        XCTAssertFalse(EmbeddedChatEngineFactory.savesKnowledge(contextType: CodeQuestionList.contextType))
        XCTAssertFalse(EmbeddedChatEngineFactory.savesKnowledge(contextType: ReviewerSurface.contextType))
        XCTAssertTrue(EmbeddedChatEngineFactory.savesKnowledge(contextType: "target"))
    }

    /// The owner's `решили:` line stored in a Discuss thread writes no idea;
    /// the same line in another embedded chat does.
    func testADecisionPrefixInAThreadWritesNoIdea() async throws {
        let factory = EmbeddedChatEngineFactory()
        factory.dbPool = pool
        let knowledge = try XCTUnwrap(factory.knowledgeCenter)
        func stored(_ contextType: String, message: Int64) async {
            let spec = ChatSurfaceSpec(
                key: EmbeddedChatKey(contextType: contextType, contextID: "3:7:da:abc", conversationID: nil),
                persistence: .memory, toolAccess: .draftOnly, ownerInstructions: true,
                systemPrompt: { "" }, turnPrompt: { $0.text }, emptyHint: "")
            let engine = factory.center.engine(for: spec)
            engine.onOwnerMessageStored?("решили: mute ends at midnight", 3, message)
            await knowledge.waitForIdle()
        }
        await stored(SpecReviewThreadKey.contextType, message: 11)
        var count = try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ideas") ?? 0 }
        XCTAssertEqual(count, 0, "a thread line never becomes a chat-born idea")

        await stored("target", message: 12)
        count = try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ideas") ?? 0 }
        XCTAssertEqual(count, 1)
    }
}

import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class TrackChatSurfaceTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do { (dbManager, dbPath) = try TestDatabase.createDatabaseManager() } catch { XCTFail("setUp failed: \(error)") }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    private func makeTrack() throws -> Track {
        let id = try dbManager.dbPool.write { db in
            try TestDatabase.insertTrack(db, channelIDs: "[\"C1\"]", participants: "[]", assigneeUserID: "")
        }
        return try XCTUnwrap(try dbManager.dbPool.read { db in
            try Track.fetchOne(db, sql: "SELECT * FROM tracks WHERE id = ?", arguments: [id])
        })
    }

    func testTheTrackKeepsOneConversation() throws {
        let track = try makeTrack()
        let first = try TrackChatSurface.conversationID(for: track, dbPool: dbManager.dbPool)
        XCTAssertEqual(try TrackChatSurface.conversationID(for: track, dbPool: dbManager.dbPool), first)
        let conv = try dbManager.dbPool.read { try ChatConversationQueries.fetchByID($0, id: first) }
        XCTAssertEqual(conv?.contextType, "track")
        XCTAssertEqual(conv?.title.hasPrefix("Track: "), true)
    }

    /// Leaving the track (the view goes, the center keeps the engine) never
    /// stops a reply (review-rules "Lifecycle & state").
    func testLeavingTheTrackNeverStopsTheReply() async throws {
        let track = try makeTrack()
        let mock = MockClaudeService(events: [.text("the latest")], thenAwaitsRelease: true)
        let pool = dbManager.dbPool
        let center = EmbeddedChatCenter { spec, _ in makeSurfaceEngine(spec, dbPool: pool, ai: mock) }
        let conv = try TrackChatSurface.conversationID(for: track, dbPool: pool)
        let spec = TrackChatSurface.spec(track: track, conversationID: conv, dbPool: pool)
        let engine = center.engine(for: spec)
        center.markShown(spec.key)
        engine.send("what's new?")
        center.markHidden(spec.key)
        mock.release()
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)
        XCTAssertTrue(center.engine(for: spec) === engine)
        XCTAssertEqual(engine.messages.last?.message.text, "the latest")
    }

    /// The question card is taught on this surface too (spec 2026-10-02).
    func testSystemPromptTeachesTheQuestionCard() throws {
        let track = try makeTrack()
        let prompt = TrackChatSurface.buildSystemPrompt(track: track, dbPool: dbManager.dbPool,
                                                        memoryChatEnabled: false, memoryVaultDir: nil, skillsDir: nil)
        XCTAssertTrue(prompt.hasSuffix(ChatQuestionsContract.promptBlock))
    }
}

import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The track Discuss surface's half of the assistant-skills wiring: its
/// `context_type` ("track") is in `SkillsCatalog.chatContextTypes`, so every
/// enabled skill reaches its prompt, and an empty catalog must leave the
/// prompt byte-identical to the no-skills-dir one.
final class TrackChatSkillsPromptTests: XCTestCase {
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

    func testSkillsBlockListsEveryEnabledSkill() throws {
        let track = try makeTrack()
        let dir = try SkillsPromptFixtures.makePair(self)

        let prompt = TrackChatSurface.buildSystemPrompt(
            track: track, dbPool: dbManager.dbPool,
            memoryChatEnabled: false, memoryVaultDir: nil, skillsDir: dir)

        XCTAssertTrue(prompt.contains("=== AVAILABLE SKILLS ==="))
        XCTAssertTrue(prompt.contains(SkillsPromptFixtures.breakdownLine))
        XCTAssertTrue(prompt.contains(SkillsPromptFixtures.untangleLine))
        XCTAssertTrue(prompt.contains("load_skill"), "the model must be told to load the skill first")
    }

    func testSkillsBlockAbsentWhenNoSkillsExist() throws {
        let track = try makeTrack()
        let empty = try SkillsPromptFixtures.makeEmptyDir(self)

        let withEmptyDir = TrackChatSurface.buildSystemPrompt(
            track: track, dbPool: dbManager.dbPool,
            memoryChatEnabled: false, memoryVaultDir: nil, skillsDir: empty)
        let withNoDir = TrackChatSurface.buildSystemPrompt(
            track: track, dbPool: dbManager.dbPool,
            memoryChatEnabled: false, memoryVaultDir: nil, skillsDir: nil)

        XCTAssertFalse(withEmptyDir.contains("AVAILABLE SKILLS"))
        XCTAssertEqual(withEmptyDir, withNoDir, "no skills must leave the prompt byte-identical")
    }

    /// AGENT-04: the track chat is draft-only — it must never carry a tool mode.
    @MainActor
    func testSendPassesNoToolMode() async throws {
        let track = try makeTrack()
        let mock = MockClaudeService(events: [.text("ok"), .done])
        let conv = try TrackChatSurface.conversationID(for: track, dbPool: dbManager.dbPool)
        let engine = makeSurfaceEngine(TrackChatSurface.spec(track: track, conversationID: conv, dbPool: dbManager.dbPool),
                                       dbPool: dbManager.dbPool, ai: mock)

        engine.send("hello")
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)

        // AGENT-04: draft-only surfaces never send a tool mode.
        XCTAssertEqual(mock.toolModes, [nil])
        XCTAssertNotNil(mock.systemPrompts.first.flatMap { $0 }, "the first turn carries the track prompt")
    }
}

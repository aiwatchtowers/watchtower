import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The track Discuss surface's half of the persona-skills wiring: it resolves
/// its persona from `SkillsCatalog.personaByContextType["track"]` (assistant),
/// so only assistant skills may reach it, and an empty catalog must leave the
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

    func testSkillsBlockListsAssistantSkillsOnly() throws {
        let track = try makeTrack()
        let dir = try SkillsPromptFixtures.makePersonaPair(self)

        let prompt = TrackChatViewModel.buildSystemPrompt(
            track: track, dbPool: dbManager.dbPool,
            memoryChatEnabled: false, memoryVaultDir: nil, skillsDir: dir)

        XCTAssertTrue(prompt.contains("=== AVAILABLE SKILLS ==="))
        XCTAssertTrue(prompt.contains(SkillsPromptFixtures.assistantLine))
        XCTAssertTrue(prompt.contains("load_skill"), "the model must be told to load the skill first")
        XCTAssertFalse(prompt.contains(SkillsPromptFixtures.secretaryName),
                       "secretary skills must not reach an assistant surface")
    }

    func testSkillsBlockAbsentWhenNoSkillsExist() throws {
        let track = try makeTrack()
        let empty = try SkillsPromptFixtures.makeEmptyDir(self)

        let withEmptyDir = TrackChatViewModel.buildSystemPrompt(
            track: track, dbPool: dbManager.dbPool,
            memoryChatEnabled: false, memoryVaultDir: nil, skillsDir: empty)
        let withNoDir = TrackChatViewModel.buildSystemPrompt(
            track: track, dbPool: dbManager.dbPool,
            memoryChatEnabled: false, memoryVaultDir: nil, skillsDir: nil)

        XCTAssertFalse(withEmptyDir.contains("AVAILABLE SKILLS"))
        XCTAssertEqual(withEmptyDir, withNoDir, "no skills must leave the prompt byte-identical")
    }
}

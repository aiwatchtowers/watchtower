import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The idea Discuss surface's half of the assistant-skills wiring: its
/// `context_type` ("idea") is in `SkillsCatalog.chatContextTypes`, so every
/// enabled skill reaches its prompt, and an empty catalog must leave the
/// prompt byte-identical to the no-skills-dir one.
final class IdeaChatSkillsPromptTests: XCTestCase {
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

    private func makeIdea() throws -> Idea {
        let id = try dbManager.dbPool.write { db in
            try TestDatabase.insertIdea(db, title: "Ship a weekly digest email", essence: "Friday digest")
        }
        return try XCTUnwrap(try dbManager.dbPool.read { db in
            try Idea.fetchOne(db, sql: "SELECT * FROM ideas WHERE id = ?", arguments: [id])
        })
    }

    func testSkillsBlockListsEveryEnabledSkill() throws {
        let idea = try makeIdea()
        let dir = try SkillsPromptFixtures.makePair(self)

        let prompt = IdeaChatViewModel.buildSystemPrompt(
            idea: idea, mentions: [], dbPool: dbManager.dbPool, skillsDir: dir)

        XCTAssertTrue(prompt.contains("=== AVAILABLE SKILLS ==="))
        XCTAssertTrue(prompt.contains(SkillsPromptFixtures.breakdownLine))
        XCTAssertTrue(prompt.contains(SkillsPromptFixtures.untangleLine))
        XCTAssertTrue(prompt.contains("load_skill"), "the model must be told to load the skill first")
    }

    func testSkillsBlockAbsentWhenNoSkillsExist() throws {
        let idea = try makeIdea()
        let empty = try SkillsPromptFixtures.makeEmptyDir(self)

        let withEmptyDir = IdeaChatViewModel.buildSystemPrompt(
            idea: idea, mentions: [], dbPool: dbManager.dbPool, skillsDir: empty)
        let withNoDir = IdeaChatViewModel.buildSystemPrompt(
            idea: idea, mentions: [], dbPool: dbManager.dbPool, skillsDir: nil)

        XCTAssertFalse(withEmptyDir.contains("AVAILABLE SKILLS"))
        XCTAssertEqual(withEmptyDir, withNoDir, "no skills must leave the prompt byte-identical")
    }
}

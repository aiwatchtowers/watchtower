import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The meeting Discuss surface's half of the assistant-skills wiring: its
/// `context_type` ("meeting") is in `SkillsCatalog.chatContextTypes`, so every
/// enabled skill reaches its prompt, and an empty catalog must leave the
/// prompt byte-identical to the no-skills-dir one.
final class MeetingChatSkillsPromptTests: XCTestCase {
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

    private func makeTranscript() throws -> MeetingTranscript {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMeetingTranscript(db, eventID: nil, transcriptText: "hello world")
        }
        return try XCTUnwrap(try dbManager.dbPool.read { db in
            try MeetingTranscript.fetchOne(
                db, sql: "SELECT * FROM meeting_transcripts ORDER BY id DESC LIMIT 1")
        })
    }

    func testSkillsBlockListsEveryEnabledSkill() throws {
        let transcript = try makeTranscript()
        let dir = try SkillsPromptFixtures.makePair(self)

        let prompt = MeetingChatViewModel.buildSystemPrompt(
            transcript: transcript, recapContent: nil, dbPool: dbManager.dbPool,
            memoryChatEnabled: false, memoryVaultDir: nil, skillsDir: dir)

        XCTAssertTrue(prompt.contains("=== AVAILABLE SKILLS ==="))
        XCTAssertTrue(prompt.contains(SkillsPromptFixtures.untangleLine))
        XCTAssertTrue(prompt.contains(SkillsPromptFixtures.breakdownLine))
        XCTAssertTrue(prompt.contains("load_skill"), "the model must be told to load the skill first")
    }

    func testSkillsBlockAbsentWhenNoSkillsExist() throws {
        let transcript = try makeTranscript()
        let empty = try SkillsPromptFixtures.makeEmptyDir(self)

        let withEmptyDir = MeetingChatViewModel.buildSystemPrompt(
            transcript: transcript, recapContent: nil, dbPool: dbManager.dbPool,
            memoryChatEnabled: false, memoryVaultDir: nil, skillsDir: empty)
        let withNoDir = MeetingChatViewModel.buildSystemPrompt(
            transcript: transcript, recapContent: nil, dbPool: dbManager.dbPool,
            memoryChatEnabled: false, memoryVaultDir: nil, skillsDir: nil)

        XCTAssertFalse(withEmptyDir.contains("AVAILABLE SKILLS"))
        XCTAssertEqual(withEmptyDir, withNoDir, "no skills must leave the prompt byte-identical")
    }
}

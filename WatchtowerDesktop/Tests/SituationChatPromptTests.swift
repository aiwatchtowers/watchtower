import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

// MARK: - SituationChatPromptTests

/// Tests for `SituationChatViewModel.buildSystemPrompt` — the pure prompt
/// builder. Split from `SituationChatViewModelTests` (which covers the VM's
/// conversation lifecycle and streaming) so each file stays focused.
@MainActor
final class SituationChatPromptTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch { XCTFail("setUp failed: \(error)") }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    private func makeSituation(title: String = "Cloudflare follow-up") throws -> Situation {
        let id = try dbManager.dbPool.write { db in
            try TestDatabase.insertSituation(
                db, title: title, summary: "second follow-up",
                whyMatters: "ball is on you", chronology: "day 1 ... day 13")
        }
        let situation = try dbManager.dbPool.read { db in
            try Situation.fetchOne(db, sql: "SELECT * FROM situations WHERE id = ?", arguments: [id])
        }
        return try XCTUnwrap(situation)
    }

    func testBuildSystemPromptIncludesCardAndSignals() throws {
        let situation = try makeSituation()
        let itemID = try dbManager.dbPool.write { db in
            try TestDatabase.insertInboxItem(db, channelID: "C1", messageTS: "1700000100.000000", snippet: "Since I didn't hear back from you")
        }
        let signals = try dbManager.dbPool.read { db in
            try InboxItem.fetchAll(db, sql: "SELECT * FROM inbox_items WHERE id = ?", arguments: [itemID])
        }

        let prompt = SituationChatViewModel.buildSystemPrompt(
            situation: situation, memberSignals: signals, dbPool: dbManager.dbPool)

        XCTAssertTrue(prompt.contains("Cloudflare follow-up"))
        XCTAssertTrue(prompt.contains("ball is on you"))
        XCTAssertTrue(prompt.contains("Since I didn't hear back from you"))
        XCTAssertTrue(prompt.contains("ready-to-send"))
        XCTAssertTrue(prompt.contains("adding NO commitments"), "draft contract must forbid inventing content")
        XCTAssertTrue(prompt.contains("never push an unsolicited draft"), "no intent → discuss, not draft")
    }

    func testBuildSystemPromptStyleBlockPresentAndAbsent() throws {
        let situation = try makeSituation()
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db)
            try db.execute(sql: "UPDATE workspace SET style_profile = 'You write tersely.'")
        }
        let with = SituationChatViewModel.buildSystemPrompt(situation: situation, memberSignals: [], dbPool: dbManager.dbPool)
        XCTAssertTrue(with.contains("You write tersely."))

        try dbManager.dbPool.write { db in
            try db.execute(sql: "UPDATE workspace SET style_profile = ''")
        }
        let without = SituationChatViewModel.buildSystemPrompt(situation: situation, memberSignals: [], dbPool: dbManager.dbPool)
        XCTAssertFalse(without.contains("OWNER'S COMMUNICATION STYLE"))
        XCTAssertTrue(without.contains("mirror the owner's own messages"), "empty style must fall back to mirroring instruction")
    }

    func testBuildSystemPromptAdvertisesLocalTools() throws {
        let situation = try makeSituation()

        let prompt = SituationChatViewModel.buildSystemPrompt(
            situation: situation, memberSignals: [], dbPool: dbManager.dbPool)

        // The model must know it has a local message-search tool and must not
        // reach for the user's claude.ai Slack connector or ask for a DB path
        // (the bug this fixes: it flailed about "authorize Slack" / "give me the
        // database path" instead of just querying the local DB).
        XCTAssertTrue(prompt.contains("list_messages"), "must advertise the local message-search tool")
        XCTAssertTrue(prompt.contains("Never ask for a database path"),
                      "must forbid asking the user for a DB path")
        XCTAssertTrue(prompt.contains("claude.ai connectors"),
                      "must forbid reaching for external claude.ai connectors")
    }

    func testBuildSystemPromptCounterpartyBriefFromPeopleCard() throws {
        let situation = try makeSituation()
        let itemID = try dbManager.dbPool.write { db -> Int64 in
            try TestDatabase.insertWorkspace(db)
            try db.execute(sql: """
                INSERT INTO people_cards (user_id, period_from, period_to, communication_guide)
                VALUES ('U9', 1.0, 2.0, 'be blunt with him')
                """)
            return try TestDatabase.insertInboxItem(db, channelID: "C1", messageTS: "1700000100.000000", senderUserID: "U9", snippet: "ping")
        }
        let signals = try dbManager.dbPool.read { db in
            try InboxItem.fetchAll(db, sql: "SELECT * FROM inbox_items WHERE id = ?", arguments: [itemID])
        }

        let prompt = SituationChatViewModel.buildSystemPrompt(situation: situation, memberSignals: signals, dbPool: dbManager.dbPool)

        XCTAssertTrue(prompt.contains("be blunt with him"))
    }

    // MARK: - Persona skills (secretary surface)

    /// Writes one skill file into a fresh temp dir and returns the dir.
    private func makeSkillsDir(_ files: [String: String]) throws -> String {
        let dir = NSTemporaryDirectory() + "skills_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            try Data(content.utf8).write(to: URL(fileURLWithPath: dir + "/" + name))
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    func testSkillsBlockListsEveryEnabledSkill() throws {
        let situation = try makeSituation()
        let dir = try makeSkillsDir([
            "thread-untangle.md": """
                ---
                description: Reconstruct who asked what in a tangled thread.
                ---
                Body.
                """,
            "target-breakdown.md": """
                ---
                description: Decompose a target into sub-targets.
                ---
                Body.
                """
        ])

        let prompt = SituationChatViewModel.buildSystemPrompt(
            situation: situation, memberSignals: [], dbPool: dbManager.dbPool, skillsDir: dir)

        XCTAssertTrue(prompt.contains("=== AVAILABLE SKILLS ==="))
        XCTAssertTrue(prompt.contains("thread-untangle — Reconstruct who asked what in a tangled thread."))
        XCTAssertTrue(prompt.contains("target-breakdown — Decompose a target into sub-targets."))
        XCTAssertTrue(prompt.contains("load_skill"), "the model must be told to load the skill first")
    }

    func testSkillsBlockAbsentWhenNoSkillsExist() throws {
        let situation = try makeSituation()
        let empty = try makeSkillsDir([:])

        let withEmptyDir = SituationChatViewModel.buildSystemPrompt(
            situation: situation, memberSignals: [], dbPool: dbManager.dbPool, skillsDir: empty)
        let withNoDir = SituationChatViewModel.buildSystemPrompt(
            situation: situation, memberSignals: [], dbPool: dbManager.dbPool, skillsDir: nil)

        XCTAssertFalse(withEmptyDir.contains("AVAILABLE SKILLS"))
        XCTAssertEqual(withEmptyDir, withNoDir, "no skills must leave the prompt byte-identical")
    }
}

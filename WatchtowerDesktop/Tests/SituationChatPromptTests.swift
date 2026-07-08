import XCTest
import GRDB
@testable import WatchtowerDesktop

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
}

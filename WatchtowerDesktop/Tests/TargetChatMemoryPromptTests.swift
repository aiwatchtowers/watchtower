import XCTest
import GRDB
@testable import WatchtowerDesktop

final class TargetChatMemoryPromptTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do { (dbManager, dbPath) = try TestDatabase.createDatabaseManager() }
        catch { XCTFail("setUp failed: \(error)") }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    private func fetchTarget(_ id: Int64) throws -> Target {
        try XCTUnwrap(try dbManager.dbPool.read { db in
            try Target.fetchOne(db, sql: "SELECT * FROM targets WHERE id = ?", arguments: [id])
        })
    }

    func testBareTargetWithNoLinkedTrackYieldsOnlyItsOwnMirrorAlias() throws {
        let targetID = try dbManager.dbPool.write { db in try TestDatabase.insertTarget(db) }
        let target = try fetchTarget(targetID)
        let subjects = TargetChatViewModel.targetMemorySubjects(target: target, dbPool: dbManager.dbPool)
        XCTAssertEqual(subjects, ["target:\(target.id)"])
    }

    func testTargetUnionsSubjectsAcrossTwoLinkedTracks() throws {
        let targetID = try dbManager.dbPool.write { db in try TestDatabase.insertTarget(db) }
        try dbManager.dbPool.write { db in
            try TestDatabase.insertTrack(db, channelIDs: "[\"C1\"]", assigneeUserID: "U1", linkedTargetID: Int(targetID))
            try TestDatabase.insertTrack(db, channelIDs: "[\"C2\"]", assigneeUserID: "U2", linkedTargetID: Int(targetID))
            // An unrelated track (no linked_target_id) must not leak in.
            try TestDatabase.insertTrack(db, channelIDs: "[\"C_other\"]", assigneeUserID: "U_other")
        }
        let target = try fetchTarget(targetID)
        let subjects = Set(TargetChatViewModel.targetMemorySubjects(target: target, dbPool: dbManager.dbPool))
        XCTAssertEqual(subjects, Set(["target:\(target.id)", "C1", "U1", "C2", "U2"]))
        XCTAssertFalse(subjects.contains("C_other"))
        XCTAssertFalse(subjects.contains("U_other"))
    }

    func testLinkedTrackMirrorAliasIsExcludedFromTargetSubjects() throws {
        let targetID = try dbManager.dbPool.write { db in try TestDatabase.insertTarget(db) }
        let trackID = try dbManager.dbPool.write { db in
            try TestDatabase.insertTrack(db, channelIDs: "[]", linkedTargetID: Int(targetID))
        }
        let target = try fetchTarget(targetID)
        let subjects = TargetChatViewModel.targetMemorySubjects(target: target, dbPool: dbManager.dbPool)
        XCTAssertFalse(subjects.contains("track:\(trackID)"), "a linked track's own mirror alias must not leak into the target's subjects")
    }

    func testMemoryBlockAppearsWhenFlagOnViaLinkedTrack() throws {
        let targetID = try dbManager.dbPool.write { db in try TestDatabase.insertTarget(db) }
        try dbManager.dbPool.write { db in
            try TestDatabase.insertTrack(db, channelIDs: "[\"C1\"]", linkedTargetID: Int(targetID))
            try TestDatabase.insertMemoryNode(db, id: "ent_cf", type: "entity", title: "Cloudflare (vendor)")
            try TestDatabase.insertMemoryAlias(db, alias: "C1", nodeID: "ent_cf")
        }
        let target = try fetchTarget(targetID)
        let prompt = TargetChatViewModel.buildSystemPrompt(
            target: target, dbPool: dbManager.dbPool, memoryChatEnabled: true, memoryVaultDir: nil)
        XCTAssertTrue(prompt.contains("=== MEMORY ("))
        XCTAssertTrue(prompt.contains("Cloudflare (vendor)"))
    }

    func testMemoryBlockAbsentWhenFlagOff() throws {
        let targetID = try dbManager.dbPool.write { db in try TestDatabase.insertTarget(db) }
        let target = try fetchTarget(targetID)
        let prompt = TargetChatViewModel.buildSystemPrompt(
            target: target, dbPool: dbManager.dbPool, memoryChatEnabled: false, memoryVaultDir: nil)
        XCTAssertFalse(prompt.contains("=== MEMORY ("))
    }
}

import XCTest
import GRDB
@testable import WatchtowerDesktop

final class TrackChatMemoryPromptTests: XCTestCase {
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

    private func makeTrack(channelIDs: String = "[\"C1\"]", assigneeUserID: String = "", participants: String = "[]") throws -> Track {
        let id = try dbManager.dbPool.write { db in
            try TestDatabase.insertTrack(db, channelIDs: channelIDs, participants: participants, assigneeUserID: assigneeUserID)
        }
        return try XCTUnwrap(try dbManager.dbPool.read { db in try Track.fetchOne(db, sql: "SELECT * FROM tracks WHERE id = ?", arguments: [id]) })
    }

    func testTrackMemorySubjectsIncludesChannelsParticipantsScalarsAndMirrorAlias() throws {
        let participants = #"[{"name":"Bob","user_id":"U2","stance":"blocker"}]"#
        let track = try makeTrack(channelIDs: "[\"C1\",\"C2\"]", assigneeUserID: "U1", participants: participants)
        let subjects = Set(TrackChatViewModel.trackMemorySubjects(track: track))
        XCTAssertEqual(subjects, Set(["track:\(track.id)", "C1", "C2", "U1", "U2"]))
    }

    func testMemoryBlockAppearsWhenFlagOnAndSubjectMatches() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_cf", type: "entity", title: "Cloudflare (vendor)")
            try TestDatabase.insertMemoryAlias(db, alias: "C1", nodeID: "ent_cf")
        }
        let track = try makeTrack(channelIDs: "[\"C1\"]")
        let prompt = TrackChatViewModel.buildSystemPrompt(
            track: track, dbPool: dbManager.dbPool, memoryChatEnabled: true, memoryVaultDir: nil)
        XCTAssertTrue(prompt.contains("=== MEMORY ("))
        XCTAssertTrue(prompt.contains("Cloudflare (vendor)"))
        XCTAssertTrue(prompt.contains("model-mediated"))
    }

    func testMemoryBlockAbsentWhenFlagOff() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_cf", type: "entity", title: "Cloudflare (vendor)")
            try TestDatabase.insertMemoryAlias(db, alias: "C1", nodeID: "ent_cf")
        }
        let track = try makeTrack(channelIDs: "[\"C1\"]")
        let prompt = TrackChatViewModel.buildSystemPrompt(
            track: track, dbPool: dbManager.dbPool, memoryChatEnabled: false, memoryVaultDir: nil)
        XCTAssertFalse(prompt.contains("=== MEMORY ("))
        XCTAssertFalse(prompt.contains("Cloudflare (vendor)"), "no memory read should leak into the prompt when disabled")
    }

    func testEmptyTrackHasOnlyMirrorAliasSubject() throws {
        let track = try makeTrack(channelIDs: "[]", participants: "[]")
        XCTAssertEqual(TrackChatViewModel.trackMemorySubjects(track: track), ["track:\(track.id)"])
    }
}

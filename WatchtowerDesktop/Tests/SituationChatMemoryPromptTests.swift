import XCTest
import GRDB
@testable import WatchtowerDesktop

// MARK: - SituationChatMemoryPromptTests

/// Tests for the Phase-4 MEMORY section in
/// `SituationChatViewModel.buildSystemPrompt` (behind `memory.surfaces.chat`).
/// The flag and vault dir are injected explicitly so the tests never touch the
/// real config.yaml or workspace directory.
@MainActor
final class SituationChatMemoryPromptTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var vaultDir: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch { XCTFail("setUp failed: \(error)") }
        vaultDir = NSTemporaryDirectory() + "memvault_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: vaultDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        try? FileManager.default.removeItem(atPath: vaultDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeSituation() throws -> Situation {
        let id = try dbManager.dbPool.write { db in
            try TestDatabase.insertSituation(
                db, title: "Cloudflare follow-up", summary: "second follow-up",
                whyMatters: "ball is on you", chronology: "day 1 ... day 13")
        }
        return try XCTUnwrap(try dbManager.dbPool.read { db in
            try Situation.fetchOne(db, sql: "SELECT * FROM situations WHERE id = ?", arguments: [id])
        })
    }

    private func signals(channelID: String = "C1", senderUserID: String = "U9") throws -> [InboxItem] {
        let itemID = try dbManager.dbPool.write { db in
            try TestDatabase.insertInboxItem(
                db, channelID: channelID, messageTS: "1700000100.000000",
                senderUserID: senderUserID, snippet: "please respond")
        }
        return try dbManager.dbPool.read { db in
            try InboxItem.fetchAll(db, sql: "SELECT * FROM inbox_items WHERE id = ?", arguments: [itemID])
        }
    }

    private func writeMap(_ text: String) {
        try? Data(text.utf8).write(to: URL(fileURLWithPath: vaultDir + "/map.md"))
    }

    private func build(
        _ situation: Situation,
        _ memberSignals: [InboxItem],
        enabled: Bool,
        vault: String?
    ) -> String {
        SituationChatViewModel.buildSystemPrompt(
            situation: situation, memberSignals: memberSignals, dbPool: dbManager.dbPool,
            memoryChatEnabled: enabled, memoryVaultDir: vault)
    }

    // MARK: - Enabled path

    func testMemorySectionPresentWithMapEntitiesAndBeliefs() throws {
        let situation = try makeSituation()
        let signals = try signals(channelID: "C1", senderUserID: "U9")
        writeMap("# Workspace map\n- billing team owns renewals\n- Cloudflare is a vendor")
        try dbManager.dbPool.write { db in
            // Entity aliased to the situation's channel + a member user id.
            try TestDatabase.insertMemoryNode(db, id: "ent_cf", type: "entity", title: "Cloudflare (vendor)")
            try TestDatabase.insertMemoryAlias(db, alias: "C1", nodeID: "ent_cf")
            try TestDatabase.insertMemoryAlias(db, alias: "U9", nodeID: "ent_cf")
            // Beliefs whose subject is that entity.
            try TestDatabase.insertMemoryNode(
                db, id: "bel_ok", type: "belief",
                title: "Cloudflare renewals close on time", subject: "ent_cf",
                confidence: 0.80, status: "active")
            try TestDatabase.insertMemoryNode(
                db, id: "bel_shaky", type: "belief",
                title: "Cloudflare support is responsive", subject: "ent_cf",
                confidence: 0.40, status: "shaken")
        }

        let prompt = build(situation, signals, enabled: true, vault: vaultDir)

        XCTAssertTrue(prompt.contains("=== MEMORY ("), "MEMORY section header must appear")
        XCTAssertTrue(prompt.contains("model-mediated"), "block must frame vault text as model-mediated")
        XCTAssertTrue(prompt.contains("billing team owns renewals"), "hot map contents must be included")
        XCTAssertTrue(prompt.contains("Cloudflare (vendor)"), "matched entity title must appear")
        XCTAssertTrue(prompt.contains("Cloudflare renewals close on time"), "active belief statement must appear")
        XCTAssertTrue(prompt.contains("(uncertain — evidence conflicts)"), "shaken belief needs the uncertainty marker")

        // MEMORY must sit before TOOLS (between owner brief and tools block).
        let memoryIdx = try XCTUnwrap(prompt.range(of: "=== MEMORY (")).lowerBound
        let toolsIdx = try XCTUnwrap(prompt.range(of: "=== TOOLS (")).lowerBound
        XCTAssertLessThan(memoryIdx, toolsIdx)
    }

    func testMemoryToolsAdvertised() throws {
        let situation = try makeSituation()
        let prompt = build(situation, [], enabled: true, vault: vaultDir)
        XCTAssertTrue(prompt.contains("memory_recall"))
        XCTAssertTrue(prompt.contains("memory_open"))
        XCTAssertTrue(prompt.contains("memory_map"))
        XCTAssertTrue(prompt.contains("check what the secretary already knows before asking the user"))
    }

    func testAbsentMapDegradesToNote() throws {
        let situation = try makeSituation()
        // No map.md written into vaultDir.
        let prompt = build(situation, [], enabled: true, vault: vaultDir)
        XCTAssertTrue(prompt.contains("=== MEMORY ("))
        XCTAssertTrue(prompt.contains("Hot map: (none yet"), "absent map must degrade to a one-line note")
    }

    func testNoMatchingEntitiesDegradesToNote() throws {
        let situation = try makeSituation()
        // A member signal, but no memory node aliases it.
        let signals = try signals(channelID: "C_other", senderUserID: "U_other")
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_cf", type: "entity", title: "Cloudflare (vendor)")
            try TestDatabase.insertMemoryAlias(db, alias: "C1", nodeID: "ent_cf")
        }
        let prompt = build(situation, signals, enabled: true, vault: vaultDir)
        XCTAssertTrue(prompt.contains("Relevant notes: (none match"))
        XCTAssertFalse(prompt.contains("Cloudflare (vendor)"), "an unaliased entity must not leak in")
    }

    func testEntitySelectionRespectsAliasJoinAndCap() throws {
        let situation = try makeSituation()
        // Six member signals with distinct senders (alias is a PK: one node per
        // alias), each with a matching entity — the cap must keep the list to 5.
        let itemIDs = try dbManager.dbPool.write { db -> [Int64] in
            var ids: [Int64] = []
            for i in 0..<6 {
                ids.append(try TestDatabase.insertInboxItem(
                    db, channelID: "C1", messageTS: "170000010\(i).000000",
                    senderUserID: "U\(i)", snippet: "ping"))
                try TestDatabase.insertMemoryNode(db, id: "ent_\(i)", type: "entity", title: "Entity number \(i)")
                try TestDatabase.insertMemoryAlias(db, alias: "U\(i)", nodeID: "ent_\(i)")
            }
            // An entity aliased to something the situation does not reference.
            try TestDatabase.insertMemoryNode(db, id: "ent_x", type: "entity", title: "Unrelated entity X")
            try TestDatabase.insertMemoryAlias(db, alias: "U_nope", nodeID: "ent_x")
            return ids
        }
        let signals = try dbManager.dbPool.read { db in
            try InboxItem.fetchAll(
                db, sql: "SELECT * FROM inbox_items WHERE id IN (\(itemIDs.map { _ in "?" }.joined(separator: ",")))",
                arguments: StatementArguments(itemIDs))
        }
        let prompt = build(situation, signals, enabled: true, vault: vaultDir)

        let matched = (0..<6).filter { prompt.contains("Entity number \($0)") }.count
        XCTAssertEqual(matched, 5, "entity list must cap at 5")
        XCTAssertFalse(prompt.contains("Unrelated entity X"), "alias join must exclude non-matching aliases")
    }

    func testMapTruncatedTo4KB() throws {
        let situation = try makeSituation()
        // 600 lines of ~12 bytes = ~7 KB, well over the 4 KB cap.
        let big = (0..<600).map { "map line \($0)" }.joined(separator: "\n")
        writeMap(big)

        let prompt = build(situation, [], enabled: true, vault: vaultDir)

        let start = try XCTUnwrap(prompt.range(of: "=== MEMORY (")).lowerBound
        let end = try XCTUnwrap(prompt.range(of: "=== TOOLS (")).lowerBound
        let section = String(prompt[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertLessThanOrEqual(section.utf8.count, 4096, "memory section must be capped at 4 KB")
        XCTAssertTrue(section.contains("map line 0"), "truncation keeps the start of the map")
        XCTAssertFalse(section.contains("map line 599"), "the tail beyond 4 KB must be dropped")
    }

    // MARK: - Disabled path (byte-identical guard)

    func testDisabledPathByteIdenticalRegardlessOfMemoryData() throws {
        let situation = try makeSituation()
        let signals = try signals(channelID: "C1", senderUserID: "U9")

        let bare = build(situation, signals, enabled: false, vault: vaultDir)

        // Now seed a full memory graph + a map and rebuild with the flag OFF.
        writeMap("# should not appear\n- secret note")
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_cf", type: "entity", title: "Cloudflare (vendor)")
            try TestDatabase.insertMemoryAlias(db, alias: "C1", nodeID: "ent_cf")
            try TestDatabase.insertMemoryNode(
                db, id: "bel_ok", type: "belief", title: "a belief", subject: "ent_cf",
                confidence: 0.9, status: "active")
        }
        let withData = build(situation, signals, enabled: false, vault: vaultDir)

        XCTAssertEqual(bare, withData, "memory data must not change a single byte when the flag is off")
        XCTAssertFalse(withData.contains("=== MEMORY ("), "no MEMORY section when disabled")
        XCTAssertFalse(withData.contains("memory_recall"), "no memory tools advertised when disabled")
        XCTAssertFalse(withData.contains("secret note"), "map contents must not leak when disabled")
    }
}

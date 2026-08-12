import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerTestSupport

final class RelevantMemoryTests: XCTestCase {
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

    // MARK: - Entities ranked by importance

    func testEntitiesRankedByImportanceNotTitle() throws {
        try dbManager.dbPool.write { db in
            // "Zebra" would sort first alphabetically; importance must win.
            // Two distinct aliases (memory_aliases.alias is a unique primary key —
            // one alias resolves to exactly one node), both present in `subjects`.
            try TestDatabase.insertMemoryNode(db, id: "ent_a", type: "entity", title: "Zebra Corp", importanceScore: 1)
            try TestDatabase.insertMemoryAlias(db, alias: "U1", nodeID: "ent_a")
            try TestDatabase.insertMemoryNode(db, id: "ent_b", type: "entity", title: "Acme Inc", importanceScore: 9)
            try TestDatabase.insertMemoryAlias(db, alias: "U2", nodeID: "ent_b")
        }
        let result = relevantMemoryContext(subjects: ["U1", "U2"], dbPool: dbManager.dbPool)
        XCTAssertEqual(result.entityTitles, ["Acme Inc", "Zebra Corp"], "higher importance_score must rank first")
    }

    func testEntitiesTitleIsDeterministicTiebreakOnEqualImportance() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_z", type: "entity", title: "Zebra Corp", importanceScore: 5)
            try TestDatabase.insertMemoryAlias(db, alias: "U1", nodeID: "ent_z")
            try TestDatabase.insertMemoryNode(db, id: "ent_a", type: "entity", title: "Acme Inc", importanceScore: 5)
            try TestDatabase.insertMemoryAlias(db, alias: "U2", nodeID: "ent_a")
        }
        let result = relevantMemoryContext(subjects: ["U1", "U2"], dbPool: dbManager.dbPool)
        XCTAssertEqual(result.entityTitles, ["Acme Inc", "Zebra Corp"], "equal importance falls back to title order")
    }

    // MARK: - Beliefs ranked by importance, confidence as tiebreak

    func testBeliefsRankedByImportanceNotConfidence() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_cf", type: "entity", title: "Cloudflare")
            try TestDatabase.insertMemoryAlias(db, alias: "U1", nodeID: "ent_cf")
            try TestDatabase.insertMemoryNode(
                db, id: "bel_low_imp_high_conf", type: "belief", title: "renewals close on time",
                subject: "ent_cf", confidence: 0.95, status: "active", importanceScore: 1)
            try TestDatabase.insertMemoryNode(
                db, id: "bel_high_imp_low_conf", type: "belief", title: "support is responsive",
                subject: "ent_cf", confidence: 0.30, status: "active", importanceScore: 9)
        }
        let result = relevantMemoryContext(subjects: ["U1"], dbPool: dbManager.dbPool)
        XCTAssertEqual(result.beliefs.first?.title, "support is responsive", "higher importance_score must rank first despite lower confidence")
    }

    func testBeliefsConfidenceIsTiebreakOnEqualImportance() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_cf", type: "entity", title: "Cloudflare")
            try TestDatabase.insertMemoryAlias(db, alias: "U1", nodeID: "ent_cf")
            try TestDatabase.insertMemoryNode(
                db, id: "bel_a", type: "belief", title: "belief A", subject: "ent_cf",
                confidence: 0.40, status: "active", importanceScore: 5)
            try TestDatabase.insertMemoryNode(
                db, id: "bel_b", type: "belief", title: "belief B", subject: "ent_cf",
                confidence: 0.90, status: "active", importanceScore: 5)
        }
        let result = relevantMemoryContext(subjects: ["U1"], dbPool: dbManager.dbPool)
        XCTAssertEqual(result.beliefs.first?.title, "belief B", "equal importance falls back to confidence order")
    }

    // MARK: - Recent (short-tier) episodes

    func testRecentEpisodesOrderedByRecencyAndDedupedPerNode() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ep_recent", type: "episode", title: "Recent episode", tier: "short")
            try TestDatabase.insertMemoryProvenance(db, nodeID: "ep_recent", channelID: "C1", tsRaw: "200.0", tsUnix: 200.0, senderID: "U1")
            // Same node, an OLDER ref from the same sender — must dedup to one row, keyed on the newest ref.
            try TestDatabase.insertMemoryProvenance(db, nodeID: "ep_recent", channelID: "C1", tsRaw: "50.0", tsUnix: 50.0, senderID: "U1")

            try TestDatabase.insertMemoryNode(db, id: "ep_older", type: "episode", title: "Older episode", tier: "short")
            try TestDatabase.insertMemoryProvenance(db, nodeID: "ep_older", channelID: "C1", tsRaw: "100.0", tsUnix: 100.0, senderID: "U1")

            try TestDatabase.insertMemoryNode(db, id: "ep_long_tier", type: "episode", title: "Long-tier episode", tier: "long")
            try TestDatabase.insertMemoryProvenance(db, nodeID: "ep_long_tier", channelID: "C1", tsRaw: "300.0", tsUnix: 300.0, senderID: "U1")

            try TestDatabase.insertMemoryNode(
                db, id: "ep_tombstoned", type: "episode", title: "Tombstoned episode", status: "tombstone", tier: "short"
            )
            try TestDatabase.insertMemoryProvenance(db, nodeID: "ep_tombstoned", channelID: "C1", tsRaw: "400.0", tsUnix: 400.0, senderID: "U1")

            try TestDatabase.insertMemoryNode(db, id: "ep_other_sender", type: "episode", title: "Other sender episode", tier: "short")
            try TestDatabase.insertMemoryProvenance(db, nodeID: "ep_other_sender", channelID: "C1", tsRaw: "500.0", tsUnix: 500.0, senderID: "U2")
        }
        let result = relevantMemoryContext(subjects: ["U1"], dbPool: dbManager.dbPool)
        XCTAssertEqual(result.recentEpisodeTitles, ["Recent episode", "Older episode"],
                       "short-tier, non-tombstone, matching-sender episodes only, newest first, deduped per node")
    }

    // MARK: - Empty / degenerate

    func testEmptySubjectsReturnsEmptyContext() throws {
        let result = relevantMemoryContext(subjects: [], dbPool: dbManager.dbPool)
        XCTAssertTrue(result.entityTitles.isEmpty)
        XCTAssertTrue(result.beliefs.isEmpty)
        XCTAssertTrue(result.recentEpisodeTitles.isEmpty)
    }

    func testNoMatchesReturnsEmptyContext() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_x", type: "entity", title: "Unrelated")
            try TestDatabase.insertMemoryAlias(db, alias: "U_other", nodeID: "ent_x")
        }
        let result = relevantMemoryContext(subjects: ["U1"], dbPool: dbManager.dbPool)
        XCTAssertTrue(result.entityTitles.isEmpty)
        XCTAssertTrue(result.beliefs.isEmpty)
        XCTAssertTrue(result.recentEpisodeTitles.isEmpty)
    }

    // MARK: - Rendering

    func testRenderMemorySectionIncludesRecentActivitySubsection() {
        let context = MemoryContextResult(
            entityTitles: ["Acme Inc"],
            beliefs: [MemoryBelief(title: "renewals close on time", confidence: 0.8, status: "active")],
            recentEpisodeTitles: ["Nova Card rollout update"])
        let section = renderMemorySection(hotMap: "- billing team owns renewals", context: context)
        XCTAssertTrue(section.contains("Recent activity"), "a new subsection must appear when recent episodes exist")
        XCTAssertTrue(section.contains("Nova Card rollout update"))
        XCTAssertTrue(section.contains("model-mediated"))
    }

    func testRenderMemorySectionOmitsRecentActivityWhenEmpty() {
        let context = MemoryContextResult(entityTitles: [], beliefs: [], recentEpisodeTitles: [])
        let section = renderMemorySection(hotMap: nil, context: context)
        XCTAssertFalse(section.contains("Recent activity"))
        XCTAssertTrue(section.contains("Relevant notes: (none match"))
    }

    func testCap4KBTruncatesOnLineBoundary() {
        let big = (0..<600).map { "line \($0)" }.joined(separator: "\n")
        let capped = cap4KB(big)
        XCTAssertLessThanOrEqual(capped.utf8.count, 4096)
        XCTAssertTrue(capped.contains("line 0"))
        XCTAssertFalse(capped.contains("line 599"))
    }
}

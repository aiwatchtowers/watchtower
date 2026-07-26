import XCTest
import GRDB
@testable import WatchtowerDesktop

final class MemoryQueriesTests: XCTestCase {

    // MARK: - fetchNodes

    func testFetchNodesExcludesTombstonesNewestFirst() throws {
        let dbQueue = try TestDatabase.create()
        try dbQueue.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_A", type: "entity", title: "Alice", indexedAt: "2026-07-17T10:00:00Z")
            try TestDatabase.insertMemoryNode(db, id: "ep_B", type: "episode", title: "Incident", indexedAt: "2026-07-17T11:00:00Z")
            try TestDatabase.insertMemoryNode(db, id: "ent_dead", type: "entity", status: "tombstone")
        }
        try dbQueue.read { db in
            let all = try MemoryQueries.fetchNodes(db)
            XCTAssertEqual(all.map(\.id), ["ep_B", "ent_A"]) // newest indexed first
        }
    }

    func testFetchNodesJoinsDisputeFlag() throws {
        let dbQueue = try TestDatabase.create()
        try dbQueue.write { db in
            try TestDatabase.insertMemoryNode(db, id: "bel_X", type: "belief", title: "Belief", confidence: 0.8)
            try TestDatabase.insertMemoryDispute(db, nodeID: "bel_X", reason: "owner disagreed")
        }
        try dbQueue.read { db in
            let node = try XCTUnwrap(MemoryQueries.fetchNode(db, id: "bel_X"))
            XCTAssertTrue(node.isDisputed)
            XCTAssertEqual(node.disputeReason, "owner disagreed")
        }
    }

    // MARK: - searchNodes

    func testSearchNodesMatchesBodyAndExcludesTombstones() throws {
        let dbQueue = try TestDatabase.create()
        try dbQueue.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ep_1", type: "episode", title: "Deploy freeze")
            try TestDatabase.insertMemoryFTS(db, id: "ep_1", title: "Deploy freeze", body: "The team froze deploys before the release.")
            try TestDatabase.insertMemoryNode(db, id: "ep_2", type: "episode", status: "tombstone")
            try TestDatabase.insertMemoryFTS(db, id: "ep_2", title: "", body: "froze deploys too")
        }
        try dbQueue.read { db in
            let hits = try MemoryQueries.searchNodes(db, query: "froze deploys")
            XCTAssertEqual(hits.map(\.id), ["ep_1"])
            XCTAssertFalse(hits[0].snippet.isEmpty)
        }
    }

    func testSearchNodesSanitizesOperatorInput() throws {
        let dbQueue = try TestDatabase.create()
        try dbQueue.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ep_1", type: "episode")
            try TestDatabase.insertMemoryFTS(db, id: "ep_1", body: "plain text here")
        }
        try dbQueue.read { db in
            // Bare operators / quote injection must not throw an FTS syntax error.
            XCTAssertNoThrow(try MemoryQueries.searchNodes(db, query: "AND OR NOT"))
            XCTAssertNoThrow(try MemoryQueries.searchNodes(db, query: "\"unbalanced"))
            let hits = try MemoryQueries.searchNodes(db, query: "plain NEAR text")
            XCTAssertEqual(hits.map(\.id), ["ep_1"])
        }
    }

    // MARK: - resolveNodeID

    func testResolveNodeIDDirectAliasAndRedirect() throws {
        let dbQueue = try TestDatabase.create()
        try dbQueue.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_A", type: "entity")
            try TestDatabase.insertMemoryAlias(db, alias: "situation:23", nodeID: "ent_A")
            try TestDatabase.insertMemoryNode(db, id: "ent_old", type: "entity", status: "tombstone", redirectTo: "ent_A")
        }
        try dbQueue.read { db in
            XCTAssertEqual(try MemoryQueries.resolveNodeID(db, target: "ent_A"), "ent_A")
            XCTAssertEqual(try MemoryQueries.resolveNodeID(db, target: "situation:23"), "ent_A")
            XCTAssertEqual(try MemoryQueries.resolveNodeID(db, target: "ent_old"), "ent_A")
            XCTAssertNil(try MemoryQueries.resolveNodeID(db, target: "nope"))
        }
    }

    // MARK: - Beliefs

    func testFetchBeliefsJoinsSubjectAndOrdersDisputedFirst() throws {
        let dbQueue = try TestDatabase.create()
        try dbQueue.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_bob", type: "entity", title: "Bob")
            try TestDatabase.insertMemoryNode(db, id: "bel_calm", type: "belief", title: "Calm belief", subject: "ent_bob", confidence: 0.9)
            try TestDatabase.insertMemoryNode(db, id: "bel_hot", type: "belief", title: "Contested belief", confidence: 0.5)
            try TestDatabase.insertMemoryNode(db, id: "bel_shaken", type: "belief", title: "Shaken belief", confidence: 0.7, status: "shaken")
            try TestDatabase.insertMemoryNode(db, id: "bel_gone", type: "belief", status: "tombstone")
            try TestDatabase.insertMemoryDispute(db, nodeID: "bel_hot")
        }
        try dbQueue.read { db in
            let beliefs = try MemoryQueries.fetchBeliefs(db)
            XCTAssertEqual(beliefs.map(\.id), ["bel_hot", "bel_shaken", "bel_calm"])
            XCTAssertEqual(beliefs[2].subjectTitle, "Bob")
            XCTAssertTrue(beliefs[0].isDisputed)
        }
    }

    // MARK: - Counts

    func testTypeAndDisputedCounts() throws {
        let dbQueue = try TestDatabase.create()
        try dbQueue.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_A", type: "entity")
            try TestDatabase.insertMemoryNode(db, id: "ent_B", type: "entity")
            try TestDatabase.insertMemoryNode(db, id: "bel_C", type: "belief")
            try TestDatabase.insertMemoryNode(db, id: "ent_dead", type: "entity", status: "tombstone")
            try TestDatabase.insertMemoryDispute(db, nodeID: "bel_C")
            // A stale flag on a tombstoned node must not inflate the badge.
            try TestDatabase.insertMemoryDispute(db, nodeID: "ent_dead")
        }
        try dbQueue.read { db in
            let counts = try MemoryQueries.fetchTypeCounts(db)
            XCTAssertEqual(counts["entity"], 2)
            XCTAssertEqual(counts["belief"], 1)
            XCTAssertEqual(try MemoryQueries.fetchDisputedCount(db), 1)
        }
    }

    // MARK: - Titles

    func testFetchTitle() throws {
        let dbQueue = try TestDatabase.create()
        try dbQueue.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_A", type: "entity", title: "Alice")
        }
        try dbQueue.read { db in
            XCTAssertEqual(try MemoryQueries.fetchTitle(db, id: "ent_A"), "Alice")
            XCTAssertNil(try MemoryQueries.fetchTitle(db, id: "missing"))
        }
    }

    // MARK: - Sort

    func testFetchNodesSortRecentIsUnchangedDefault() throws {
        let dbQueue = try TestDatabase.create()
        try dbQueue.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_A", type: "entity", title: "Alice", indexedAt: "2026-07-17T11:00:00Z", importanceScore: 1.0)
            try TestDatabase.insertMemoryNode(db, id: "ep_B", type: "episode", title: "Incident", indexedAt: "2026-07-17T10:00:00Z", importanceScore: 9.0)
        }
        try dbQueue.read { db in
            let all = try MemoryQueries.fetchNodes(db)
            XCTAssertEqual(all.map(\.id), ["ent_A", "ep_B"], "default sort stays newest-indexed-first, unaffected by importance")
        }
    }

    func testFetchNodesSortImportantOrdersByImportanceScoreDesc() throws {
        let dbQueue = try TestDatabase.create()
        try dbQueue.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_A", type: "entity", title: "Alice", indexedAt: "2026-07-17T11:00:00Z", importanceScore: 1.0)
            try TestDatabase.insertMemoryNode(db, id: "ep_B", type: "episode", title: "Incident", indexedAt: "2026-07-17T10:00:00Z", importanceScore: 9.0)
        }
        try dbQueue.read { db in
            let all = try MemoryQueries.fetchNodes(db, sort: .important)
            XCTAssertEqual(all.map(\.id), ["ep_B", "ent_A"], "highest importance_score first, even though it's the older-indexed node")
            XCTAssertEqual(all[0].importanceScore, 9.0)
        }
    }
}

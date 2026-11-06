import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The Inbox menu's reads: the tree in pre-order, artifacts per folder
/// through `inbox_artifact_folders`, the older-database fallback.
final class InboxFolderQueriesTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    func testTreeIsPreOrderByPositionWithRevisionAndRoutes() throws {
        let ids = try pool.write { db -> [String: Int64] in
            let seed = try InboxFolderFixtures.seed(db, revision: 7)
            let b = try InboxFolderFixtures.folder(db, parent: seed.root, slug: "b", position: 2)
            let a = try InboxFolderFixtures.folder(db, parent: seed.root, slug: "a", position: 1)
            let a2 = try InboxFolderFixtures.folder(db, parent: a, slug: "a2", position: 1)
            let a1 = try InboxFolderFixtures.folder(db, parent: a, slug: "a1", position: 0, icon: "flag")
            let automation = try TestDatabase.insertAutomation(db)
            try InboxFolderFixtures.route(db, automation: automation, folder: a1)
            return ["root": seed.root, "approvals": seed.approvals, "a": a, "a1": a1, "a2": a2, "b": b,
                    "automation": automation]
        }

        let tree = try pool.read { try InboxFolderQueries.tree($0) }

        XCTAssertEqual(tree.revision, 7)
        XCTAssertEqual(tree.folders.map(\.slug), ["inbox", "needs-approval", "a", "a1", "a2", "b"])
        XCTAssertEqual(tree.root.id, ids["root"])
        XCTAssertEqual(tree.approvals?.id, ids["approvals"])
        XCTAssertEqual(tree.folder(try XCTUnwrap(ids["a1"]))?.parentID, ids["a"])
        XCTAssertEqual(tree.folder(try XCTUnwrap(ids["a1"]))?.icon, "flag")
        XCTAssertEqual(tree.folder(try XCTUnwrap(ids["a1"]))?.kind, .owner)
        XCTAssertNil(tree.root.parentID)
        XCTAssertEqual(tree.routes, [try XCTUnwrap(ids["automation"]): try XCTUnwrap(ids["a1"])])
    }

    func testHiddenFolderAndItsSubtreeAreNotVisible() throws {
        let ids = try pool.write { db -> (hidden: Int64, child: Int64, shown: Int64) in
            let seed = try InboxFolderFixtures.seed(db)
            let hidden = try InboxFolderFixtures.folder(db, parent: seed.root, slug: "h", position: 1, hidden: true)
            let child = try InboxFolderFixtures.folder(db, parent: hidden, slug: "hc", position: 0)
            let shown = try InboxFolderFixtures.folder(db, parent: seed.root, slug: "s", position: 2)
            return (hidden, child, shown)
        }

        let tree = try pool.read { try InboxFolderQueries.tree($0) }

        XCTAssertFalse(tree.isVisible(ids.hidden))
        XCTAssertFalse(tree.isVisible(ids.child), "below a hidden folder")
        XCTAssertTrue(tree.isVisible(ids.shown))
        XCTAssertTrue(tree.isVisible(tree.root.id))
        XCTAssertFalse(tree.isVisible(9999), "an unknown folder")
        XCTAssertEqual(tree.folders.count, 5, "hidden folders are still read")
    }

    func testTreeOnSchemaWithoutTablesIsRootOnly() throws {
        try pool.write { db in
            let automation = try TestDatabase.insertAutomation(db)
            let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
            try TestDatabase.insertAutomationOutput(db, automationID: automation, runID: run)
            try db.execute(sql: "DROP VIEW inbox_artifact_folders")
            try db.execute(sql: "DROP TABLE inbox_folder_routes")
            try db.execute(sql: "DROP TABLE inbox_folder_state")
            try db.execute(sql: "UPDATE automation_outputs SET folder_id = NULL")
        }
        // automation_outputs.folder_id references the table: rebuild-free
        // drop needs the foreign keys off, as on an older file that never had it.
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DROP TABLE inbox_folders")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let (tree, artifacts) = try pool.read { db in
            let tree = try InboxFolderQueries.tree(db)
            return (tree, try InboxFolderQueries.artifactsByFolder(db, tree: tree))
        }

        XCTAssertEqual(tree, .rootOnly)
        XCTAssertEqual(tree.folders.map(\.kind), [.root])
        XCTAssertEqual(artifacts[tree.root.id]?.count, 1, "every artifact shows in the root")
    }

    func testTablesWithoutSeedRowsReadRootOnly() throws {
        let tree = try pool.read { try InboxFolderQueries.tree($0) }
        XCTAssertEqual(tree, .rootOnly)
    }

    func testArtifactsPerFolderThroughTheView() throws {
        let ids = try pool.write { db -> [String: Int64] in
            let seed = try InboxFolderFixtures.seed(db)
            let release = try InboxFolderFixtures.folder(db, parent: seed.root, slug: "release", position: 1)
            let other = try InboxFolderFixtures.folder(db, parent: seed.root, slug: "other", position: 2)
            let routed = try TestDatabase.insertAutomation(db, slug: "routed")
            let plain = try TestDatabase.insertAutomation(db, slug: "plain")
            try InboxFolderFixtures.route(db, automation: routed, folder: release)
            let routedRun = try TestDatabase.insertAutomationRun(db, automationID: routed)
            let plainRun = try TestDatabase.insertAutomationRun(db, automationID: plain)
            let older = try TestDatabase.insertAutomationOutput(
                db, automationID: routed, runID: routedRun, changedAt: "2026-10-01T09:00:00Z")
            let newer = try TestDatabase.insertAutomationOutput(
                db, automationID: routed, runID: routedRun, changedAt: "2026-10-02T09:00:00Z")
            let explicit = try TestDatabase.insertAutomationOutput(db, automationID: routed, runID: routedRun)
            try db.execute(sql: "UPDATE automation_outputs SET folder_id = ? WHERE id = ?", arguments: [other, explicit])
            let rootOne = try TestDatabase.insertAutomationOutput(db, automationID: plain, runID: plainRun)
            try TestDatabase.insertAutomationOutput(
                db, automationID: plain, runID: plainRun, doneAt: "2026-10-03T09:00:00Z")
            try TestDatabase.insertAutomationOutput(db, automationID: plain, runID: plainRun, kind: "report")
            return ["root": seed.root, "release": release, "other": other, "older": older, "newer": newer,
                    "explicit": explicit, "rootOne": rootOne]
        }

        let (byFolder, release) = try pool.read { db in
            let tree = try InboxFolderQueries.tree(db)
            return (try InboxFolderQueries.artifactsByFolder(db, tree: tree),
                    try InboxFolderQueries.artifacts(db, folderID: try XCTUnwrap(ids["release"])))
        }

        XCTAssertEqual(release.map(\.id), [try XCTUnwrap(ids["newer"]), try XCTUnwrap(ids["older"])], "the route, newest change first")
        XCTAssertEqual(byFolder[try XCTUnwrap(ids["other"])]?.map(\.id), [try XCTUnwrap(ids["explicit"])], "an explicit folder beats the route")
        XCTAssertEqual(byFolder[try XCTUnwrap(ids["root"])]?.map(\.id), [try XCTUnwrap(ids["rootOne"])],
                       "no route = the root; done and report outputs are not listed")
    }

    func testMessagesStandInUntilWaitingForMeSucceeds() throws {
        XCTAssertTrue(try pool.read { try InboxFolderQueries.messagesStandIn($0) }, "no built-in row")
        let automation = try pool.write { db -> Int64 in
            let id = try TestDatabase.insertAutomation(db, slug: "waiting-for-me")
            try db.execute(sql: """
                UPDATE automations SET origin = 'builtin', builtin_id = 'waiting-for-me', path = 'builtin:waiting-for-me'
                WHERE id = ?
                """, arguments: [id])
            return id
        }
        XCTAssertTrue(try pool.read { try InboxFolderQueries.messagesStandIn($0) }, "never ran")

        try pool.write { _ = try TestDatabase.insertAutomationRun($0, automationID: automation, status: "succeeded") }
        XCTAssertFalse(try pool.read { try InboxFolderQueries.messagesStandIn($0) })

        try pool.write { _ = try TestDatabase.insertAutomationRun($0, automationID: automation, status: "running") }
        XCTAssertFalse(try pool.read { try InboxFolderQueries.messagesStandIn($0) }, "a run under way keeps the last result")

        try pool.write { _ = try TestDatabase.insertAutomationRun($0, automationID: automation, status: "failed") }
        XCTAssertTrue(try pool.read { try InboxFolderQueries.messagesStandIn($0) }, "the last finished run failed")
    }
}

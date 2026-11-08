import XCTest
import GRDB
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// The Inbox's ⋯ menus and **+ New Artifact…** as the app wires them (B
/// Task 14): a write that landed reaches its caller as success, not as
/// "the Inbox menu is not loaded yet".
@MainActor
final class AppStateInboxArtifactMenuTests: XCTestCase {
    private var pool: DatabasePool!
    private var path = ""
    private var release: Int64 = 0
    private var automation: Int64 = 0

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
        (release, automation) = try await pool.write { db in
            // Migration 00176's seed rows (the test schema is DDL only), one owner folder.
            try db.execute(sql: """
                INSERT INTO inbox_folders (kind, parent_id, slug, title, position) VALUES ('root', NULL, 'inbox', 'Inbox', 0)
                """)
            let root = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO inbox_folders (kind, parent_id, slug, title, position)
                VALUES ('approvals', ?, 'needs-approval', 'Needs approval', 0)
                """, arguments: [root])
            try db.execute(sql: """
                INSERT INTO inbox_folders (kind, parent_id, slug, title, position) VALUES ('owner', ?, 'release', 'Release', 1)
                """, arguments: [root])
            let release = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO inbox_folder_state (id, revision) VALUES (1, 7)")
            let automation = try TestDatabase.insertAutomation(db, slug: "roundup", name: "Weekly mail roundup")
            return (release, automation)
        }
    }

    override func tearDown() async throws {
        TestDatabase.cleanup(path: path)
        pool = nil
    }

    /// `route --json`'s pinned keys.
    private func routeJSON() -> Data {
        Data((#"{"revision":8,"automation_id":\#(automation),"created":false,"folder":{"id":\#(release),"#
            + #""kind":"owner","slug":"release","title":"Release","icon":"","parent_id":1,"position":1,"#
            + #""hidden":false,"automation_ids":[\#(automation)]}}"#).utf8)
    }

    /// A save from **+ New Artifact…** whose route lands: the app's hook
    /// answers nil, so no "Saved. The folder was not created" line.
    func testSavedAutomationRouteThatLandsIsNoFailure() async throws {
        let runner = FakeCLIRunner(stdout: routeJSON())
        let appState = AppState.isolated()
        appState.initActionStrip(dbPool: pool, cliRunner: runner)
        await appState.actionStripViewModel?.folderMenu.reload()
        let vm = AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: runner))
        appState.wireInboxRoute(vm)

        let reason = await vm.routeSavedAutomation(automation, release, false)

        XCTAssertNil(reason)
        XCTAssertEqual(runner.invocations.filter { $0.starts(with: ["inbox", "folders", "route"]) }.count, 1)
    }
}

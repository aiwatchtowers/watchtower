import XCTest
import GRDB
@testable import WatchtowerDesktop

/// End-to-end VM tests over a real temp vault directory next to a file-based
/// DB pool — the same layout the app sees (<workspace>/watchtower.db +
/// <workspace>/memory/).
@MainActor
final class MemoryViewModelTests: XCTestCase {
    private var dbPath = ""
    private var workspaceDir = ""
    private var pool: DatabasePool!

    private func makeVM() throws -> MemoryViewModel {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        dbPath = path
        workspaceDir = (path as NSString).deletingLastPathComponent
        pool = manager.dbPool
        return MemoryViewModel(dbPool: manager.dbPool)
    }

    private var vaultDir: String { workspaceDir + "/memory" }

    private func writeVaultFile(_ relPath: String, _ contents: String) throws {
        let url = URL(fileURLWithPath: vaultDir).appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        try? FileManager.default.removeItem(atPath: vaultDir)
        super.tearDown()
    }

    func testSelectLoadsBodyRendersLinksAndBacklinks() async throws {
        let vm = try makeVM()
        try writeVaultFile("entities/ent_A.md", """
        ---
        id: ent_A
        type: entity
        tier: long
        status: active
        ---
        # Alice

        Works with [[ent_B|Bob]].
        """)
        try writeVaultFile("entities/ent_B.md", """
        ---
        id: ent_B
        type: entity
        tier: long
        status: active
        ---
        # Bob

        Plain page.
        """)
        try await pool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_A", type: "entity", title: "Alice", path: "entities/ent_A.md")
            try TestDatabase.insertMemoryNode(db, id: "ent_B", type: "entity", title: "Bob", path: "entities/ent_B.md")
        }

        await vm.refresh()
        await vm.select(id: "ent_A")

        let detail = try XCTUnwrap(vm.detail)
        XCTAssertEqual(detail.node.id, "ent_A")
        XCTAssertTrue(detail.raw.contains("# Alice"))
        XCTAssertTrue(detail.renderedBody.contains("[Bob](watchtower-memory://open/ent_B)"))

        // ent_B is linked from ent_A → backlink shows on ent_B.
        await vm.select(id: "ent_B")
        let detailB = try XCTUnwrap(vm.detail)
        XCTAssertEqual(detailB.backlinks.map(\.id), ["ent_A"])
    }

    func testSaveEditWritesFile() async throws {
        let vm = try makeVM()
        try writeVaultFile("entities/ent_A.md", "---\nid: ent_A\ntype: entity\ntier: long\nstatus: active\n---\n# Alice\n")
        try await pool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_A", type: "entity", title: "Alice", path: "entities/ent_A.md")
        }
        await vm.refresh()
        await vm.select(id: "ent_A")

        vm.startEditing()
        XCTAssertTrue(vm.isEditing)
        vm.editorText += "\nOwner note.\n"
        await vm.saveEdit()

        XCTAssertNil(vm.editorError)
        XCTAssertFalse(vm.isEditing)
        let onDisk = try String(contentsOfFile: vaultDir + "/entities/ent_A.md", encoding: .utf8)
        XCTAssertTrue(onDisk.contains("Owner note."))
    }

    func testSaveEditFailsWhileMemoryRunHoldsLock() async throws {
        let vm = try makeVM()
        try writeVaultFile("entities/ent_A.md", "---\nid: ent_A\ntype: entity\ntier: long\nstatus: active\n---\n# Alice\n")
        try await pool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_A", type: "entity", title: "Alice", path: "entities/ent_A.md")
        }
        await vm.refresh()
        await vm.select(id: "ent_A")

        // Simulate a running memory pipeline: hold the flock the Go side takes.
        let lockPath = workspaceDir + "/memory.lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }

        vm.startEditing()
        vm.editorText += "\nBlocked edit.\n"
        await vm.saveEdit()

        XCTAssertNotNil(vm.editorError)
        XCTAssertTrue(vm.isEditing) // stays open so the edit isn't lost
        let onDisk = try String(contentsOfFile: vaultDir + "/entities/ent_A.md", encoding: .utf8)
        XCTAssertFalse(onDisk.contains("Blocked edit."))
    }

    func testVaultMissingReportsNotInitialized() throws {
        let vm = try makeVM()
        XCTAssertFalse(vm.vaultExists)
    }

    func testRefreshSortTogglesNodeOrder() async throws {
        let vm = try makeVM()
        try await pool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_A", type: "entity", title: "Alice", indexedAt: "2026-07-17T11:00:00Z", importanceScore: 1.0)
            try TestDatabase.insertMemoryNode(db, id: "ep_B", type: "episode", title: "Incident", indexedAt: "2026-07-17T10:00:00Z", importanceScore: 9.0)
        }
        await vm.refresh()
        XCTAssertEqual(vm.nodes.map(\.id), ["ent_A", "ep_B"], "default .recent sort: newest indexed first")

        vm.sort = .important
        await vm.refresh()
        XCTAssertEqual(vm.nodes.map(\.id), ["ep_B", "ent_A"], ".important sort: highest importance_score first")
    }

    func testAliasLinkFoldsIntoBacklink() async throws {
        let vm = try makeVM()
        try writeVaultFile("episodes/ep_S.md", """
        ---
        id: ep_S
        type: episode
        tier: short
        status: active
        aliases: ["situation:23"]
        ---
        # The situation
        """)
        try writeVaultFile("entities/ent_A.md", """
        ---
        id: ent_A
        type: entity
        tier: long
        status: active
        ---
        # Alice

        Came out of [[situation:23|that mess]].
        """)
        try await pool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ep_S", type: "episode", title: "The situation", path: "episodes/ep_S.md")
            try TestDatabase.insertMemoryNode(db, id: "ent_A", type: "entity", title: "Alice", path: "entities/ent_A.md")
            try TestDatabase.insertMemoryAlias(db, alias: "situation:23", nodeID: "ep_S")
        }

        await vm.refresh()
        await vm.select(id: "ep_S")

        let detail = try XCTUnwrap(vm.detail)
        XCTAssertEqual(detail.backlinks.map(\.id), ["ent_A"])
    }

    func testOpenURLNavigatesThroughAlias() async throws {
        let vm = try makeVM()
        try writeVaultFile("episodes/ep_S.md", "---\nid: ep_S\ntype: episode\ntier: short\nstatus: active\n---\n# The situation\n")
        try await pool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ep_S", type: "episode", title: "The situation", path: "episodes/ep_S.md")
            try TestDatabase.insertMemoryAlias(db, alias: "situation:23", nodeID: "ep_S")
        }
        await vm.refresh()

        let urlString = try XCTUnwrap(MemoryMarkdown.linkURL(for: "situation:23"))
        vm.openWikiLink(url: try XCTUnwrap(URL(string: urlString)))
        // open() resolves + selects in a fire-and-forget Task; poll briefly.
        for _ in 0..<50 where vm.detail == nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(vm.detail?.node.id, "ep_S")
    }

    func testUnreadableFileDisablesEditingAndNeverOverwrites() async throws {
        let vm = try makeVM()
        // Index row points at a file that does not exist on disk.
        try FileManager.default.createDirectory(atPath: vaultDir, withIntermediateDirectories: true)
        try await pool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_gone", type: "entity", title: "Ghost", path: "entities/ent_gone.md")
        }
        await vm.refresh()
        await vm.select(id: "ent_gone")

        let detail = try XCTUnwrap(vm.detail)
        XCTAssertNotNil(detail.fileReadError)
        XCTAssertFalse(detail.isEditable)

        vm.startEditing()
        XCTAssertFalse(vm.isEditing) // editing refused — nothing to overwrite with
        await vm.saveEdit()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: vaultDir + "/entities/ent_gone.md"),
            "a failed read must never be persisted as an empty file"
        )
    }
}

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
        XCTAssertTrue(detail.file.body.contains("# Alice"))
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
}

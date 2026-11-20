import Foundation
import GRDB
import Testing
import WatchtowerTestSupport

/// Test helpers' temp folders do not pile up in $TMPDIR (#2130): every one is
/// registered with a registry whose exit hook drains it, and draining works
/// while a test still holds the database open (WAL and SHM included). Only
/// the folders these tests create are checked, never the shared $TMPDIR.
@Suite("TestTempDirectories")
struct TestTempDirectoriesTests {
    private final class HookCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private func writeRow(_ pool: DatabasePool) throws {
        try pool.write { db in
            try db.execute(sql: "INSERT INTO workspace (id, name, domain) VALUES ('T1', 'acme', 'acme')")
        }
    }

    private func makeDir() throws -> String {
        let dir = NSTemporaryDirectory() + "watchtower_test_guard_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a registry installs its exit hook once, on the first registration")
    func hookInstalledOnce() throws {
        let hooks = HookCount()
        let registry = TestTempPathRegistry { hooks.bump() }
        #expect(hooks.value == 0)
        let dirs = try (0..<3).map { _ in try makeDir() }
        dirs.forEach(registry.register)
        #expect(hooks.value == 1)
        registry.drain()
        dirs.forEach { #expect(!FileManager.default.fileExists(atPath: $0)) }
    }

    @Test("drain removes a folder holding an open WAL database and clears the list")
    func drainRemovesOpenDatabaseFolder() throws {
        let registry = TestTempPathRegistry {}
        let dir = try makeDir()
        let path = dir + "/watchtower.db"
        let pool = try DatabasePool(path: path)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE t (x INTEGER)")
            try db.execute(sql: "INSERT INTO t VALUES (1)")
        }
        #expect(FileManager.default.fileExists(atPath: path + "-wal"))
        #expect(FileManager.default.fileExists(atPath: path + "-shm"))
        registry.register(dir)

        registry.drain()

        #expect(!FileManager.default.fileExists(atPath: dir))
        #expect(!registry.isRegistered(dir))
        _ = pool // still open while its folder went
    }

    @Test("createPool registers its folder with the process registry")
    func createPoolRegistered() throws {
        let (pool, path) = try TestDatabase.createPool()
        try writeRow(pool)
        let dir = (path as NSString).deletingLastPathComponent
        #expect(TestTempDirectories.shared.isRegistered(dir))
        TestDatabase.cleanup(path: path)
        #expect(!FileManager.default.fileExists(atPath: dir))
        _ = pool
    }

    @Test("make creates an empty folder under the prefix and registers it")
    func makeRegisters() throws {
        let dir = try TestTempDirectories.make(prefix: "watchtower_test_guard_")
        #expect(FileManager.default.fileExists(atPath: dir))
        #expect((dir as NSString).lastPathComponent.hasPrefix("watchtower_test_guard_"))
        #expect(TestTempDirectories.shared.isRegistered(dir))
        try FileManager.default.removeItem(atPath: dir)
    }
}

import Foundation
import GRDB
import Testing
import WatchtowerTestSupport

/// Test helpers' temp folders do not pile up in $TMPDIR (#2130): every one is
/// registered for removal when the process exits, and removal works while a
/// test still holds the database open (WAL and SHM included). Only the
/// folders these tests create are checked, never the shared $TMPDIR.
@Suite("TestTempDirectories")
struct TestTempDirectoriesTests {
    private func writeRow(_ pool: DatabasePool) throws {
        try pool.write { db in
            try db.execute(sql: "INSERT INTO workspace (id, name, domain) VALUES ('T1', 'acme', 'acme')")
        }
    }

    @Test("createPool's folder is registered for removal at exit, and removal takes the open WAL database")
    func createPoolFolderRemoved() throws {
        let (pool, path) = try TestDatabase.createPool()
        try writeRow(pool)
        let dir = (path as NSString).deletingLastPathComponent
        #expect(FileManager.default.fileExists(atPath: path + "-wal"))
        #expect(TestTempDirectories.isRegistered(dir))

        TestTempDirectories.remove([dir])

        #expect(!FileManager.default.fileExists(atPath: dir))
        _ = pool // still open while its folder went
    }

    @Test("TestDatabase.cleanup removes the pool's folder with its -wal and -shm")
    func cleanupRemovesFolder() throws {
        let (pool, path) = try TestDatabase.createPool()
        try writeRow(pool)
        let dir = (path as NSString).deletingLastPathComponent

        TestDatabase.cleanup(path: path)

        #expect(!FileManager.default.fileExists(atPath: dir))
        _ = pool
    }

    @Test("make creates an empty folder under the prefix and registers it")
    func makeRegisters() throws {
        let dir = try TestTempDirectories.make(prefix: "watchtower_test_guard_")
        #expect(FileManager.default.fileExists(atPath: dir))
        #expect((dir as NSString).lastPathComponent.hasPrefix("watchtower_test_guard_"))
        #expect(TestTempDirectories.isRegistered(dir))

        TestTempDirectories.remove([dir])
        #expect(!FileManager.default.fileExists(atPath: dir))
    }
}

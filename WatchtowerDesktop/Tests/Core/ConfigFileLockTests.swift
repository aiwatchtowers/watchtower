import XCTest
import WatchtowerCore
import WatchtowerTestSupport

/// The `config.yaml` write lock and its only writer (spec §11, Decision 7 of
/// the background-AI-consent plan). A second holder is probed with a
/// non-blocking `flock`, never a wait.
final class ConfigFileLockTests: XCTestCase {
    private func tempConfigPath(_ name: String = "config.yaml") -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("config-lock-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent(name).path
    }

    func testSecondNonBlockingLockFails() throws {
        let configPath = tempConfigPath()
        try ConfigFileLock.withLock(configPath: configPath) { token in
            XCTAssertTrue(token.covers(configPath))
            XCTAssertTrue(RecordingConfigFileAccess.isLocked(configPath), "a second holder must not get the lock")
        }
        XCTAssertFalse(RecordingConfigFileAccess.isLocked(configPath), "the lock is free once withLock returns")
        let mode = try FileManager.default.attributesOfItem(
            atPath: ConfigFileLock.lockPath(for: configPath)
        )[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    /// Dual path: Go's `TestWithWriteLock_SharedLockFileFixture` reads the
    /// same fixture, so both languages lock one file.
    func testGoAndSwiftShareTheLockFile() throws {
        let fixture = URL(fileURLWithPath: #filePath)   // …/WatchtowerDesktop/Tests/Core/<this file>
            .deletingLastPathComponent()                 // …/Tests/Core
            .deletingLastPathComponent()                 // …/Tests
            .deletingLastPathComponent()                 // …/WatchtowerDesktop
            .deletingLastPathComponent()                 // repo root
            .appendingPathComponent("internal/config/testdata/write_lock.json")
        let names = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: String]
        )
        let configName = try XCTUnwrap(names["config"])
        let lockName = try XCTUnwrap(names["lock"])

        let configPath = tempConfigPath(configName)
        let dir = (configPath as NSString).deletingLastPathComponent
        XCTAssertEqual(ConfigFileLock.lockPath(for: configPath), configPath + ".lock")
        XCTAssertEqual(ConfigFileLock.lockPath(for: configPath), (dir as NSString).appendingPathComponent(lockName))
        try ConfigFileLock.withLock(configPath: configPath) { _ in
            XCTAssertTrue(FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(lockName)))
        }
    }

    func testNestedLockFailsFast() throws {
        let configPath = tempConfigPath()
        var nested: Error?
        try ConfigFileLock.withLock(configPath: configPath) { _ in
            XCTAssertThrowsError(try ConfigFileLock.withLock(configPath: configPath) { _ in
                XCTFail("the nested body must not run")
            }) { nested = $0 }
        }
        XCTAssertEqual(nested as? ConfigFileLock.LockError, .heldByThisProcess)
        // The held mark is cleared: the next call takes the lock again.
        try ConfigFileLock.withLock(configPath: configPath) { _ in }
    }

    func testTokenCoversOnlyItsPathWhileHeld() throws {
        let configPath = tempConfigPath()
        let dir = (configPath as NSString).deletingLastPathComponent
        var kept: ConfigFileLock.Token?
        try ConfigFileLock.withLock(configPath: configPath) { token in
            XCTAssertTrue(token.covers((dir as NSString).appendingPathComponent("./config.yaml")))
            XCTAssertFalse(token.covers((dir as NSString).appendingPathComponent("other.yaml")))
            kept = token
        }
        XCTAssertFalse(try XCTUnwrap(kept).covers(configPath), "a token kept past its body covers nothing")
    }

    func testWriterWritesOwnerOnlyAndAtomically() throws {
        let configPath = tempConfigPath("nested/config.yaml")
        try ConfigFileLock.withLock(configPath: configPath) { token in
            try ConfigFileWriter.write("a: 1\n", configPath: configPath, token: token)
        }
        XCTAssertEqual(try String(contentsOfFile: configPath, encoding: .utf8), "a: 1\n")
        let mode = try FileManager.default.attributesOfItem(atPath: configPath)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let dir = (configPath as NSString).deletingLastPathComponent
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dir).sorted(),
            ["config.yaml", "config.yaml.lock"],
            "no staged file left"
        )
    }

    func testWriterRefusesAPathItsTokenDoesNotCover() throws {
        let configPath = tempConfigPath()
        let other = (configPath as NSString).deletingLastPathComponent + "/other.yaml"
        var kept: ConfigFileLock.Token?
        try ConfigFileLock.withLock(configPath: configPath) { token in
            XCTAssertThrowsError(try ConfigFileWriter.write("a: 1\n", configPath: other, token: token)) {
                XCTAssertEqual($0 as? ConfigFileWriter.WriteError, .notLocked)
            }
            kept = token
        }
        XCTAssertThrowsError(try ConfigFileWriter.write("a: 1\n", configPath: configPath, token: XCTUnwrap(kept))) {
            XCTAssertEqual($0 as? ConfigFileWriter.WriteError, .notLocked, "a stale token writes nothing")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: other))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))
    }
}

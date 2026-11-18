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

    // MARK: - Bounded wait (the Desktop never blocks in flock)

    /// Holds the lock on `configPath` through a descriptor of its own, as
    /// another process would; `release()` lets it go.
    private final class OtherHolder: @unchecked Sendable {
        private let fd: Int32
        init(_ configPath: String) throws {
            try FileManager.default.createDirectory(
                atPath: (configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true
            )
            fd = open(ConfigFileLock.lockPath(for: configPath), O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ConfigFileLock.LockError.system(errno) }
        }
        func release() { flock(fd, LOCK_UN) }
        deinit { close(fd) }
    }

    private final class Sleeps: @unchecked Sendable {
        private let lock = NSLock()
        private var slept: [TimeInterval] = []
        var onSleep: (() -> Void)?
        var all: [TimeInterval] { lock.withLock { slept } }
        func sleep(_ interval: TimeInterval) {
            lock.withLock { slept.append(interval) }
            onSleep?()
        }
    }

    func testBusyLockThrowsRetryableErrorAfterBoundedWait() throws {
        let configPath = tempConfigPath()
        let holder = try OtherHolder(configPath)
        defer { holder.release() }
        let sleeps = Sleeps()
        let wait = ConfigFileLock.Wait(attempts: 41, interval: 0.05) { sleeps.sleep($0) }

        XCTAssertThrowsError(try ConfigFileLock.withLock(configPath: configPath, wait: wait) { _ in
            XCTFail("the body must not run without the lock")
        }) { error in
            XCTAssertEqual(error as? ConfigFileLock.LockError, .busy)
            XCTAssertEqual(error.localizedDescription, "Settings are being saved by another Watchtower process. Try again.")
        }
        XCTAssertEqual(sleeps.all.count, 40)
        XCTAssertEqual(sleeps.all.reduce(0, +), 2.0, accuracy: 0.001, "about 2 s in all")
        // The standard wait is the same bound.
        XCTAssertEqual(Double(ConfigFileLock.Wait.standard.attempts - 1) * ConfigFileLock.Wait.standard.interval, 2.0, accuracy: 0.001)
    }

    func testLockFreedDuringTheWaitIsTaken() throws {
        let configPath = tempConfigPath()
        let holder = try OtherHolder(configPath)
        let sleeps = Sleeps()
        sleeps.onSleep = { holder.release() }
        let wait = ConfigFileLock.Wait(attempts: 41, interval: 0.05) { sleeps.sleep($0) }

        let ran = try ConfigFileLock.withLock(configPath: configPath, wait: wait) { token in token.covers(configPath) }
        XCTAssertTrue(ran)
        XCTAssertEqual(sleeps.all.count, 1)
    }

    func testCopiedTokenStopsCoveringAfterRelease() throws {
        let configPath = tempConfigPath()
        var copy: ConfigFileLock.Token?
        try ConfigFileLock.withLock(configPath: configPath) { token in
            let duplicate = token
            copy = duplicate
            XCTAssertTrue(duplicate.covers(configPath))
        }
        XCTAssertFalse(try XCTUnwrap(copy).covers(configPath))
    }
}

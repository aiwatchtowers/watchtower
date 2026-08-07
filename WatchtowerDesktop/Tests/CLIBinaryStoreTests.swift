import XCTest
@testable import WatchtowerDesktop

final class CLIBinaryStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func write(_ name: String, _ content: String) throws -> String {
        let path = dir.appendingPathComponent(name).path
        try Data(content.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func storePath() -> String {
        // Nested dir that does not exist yet — sync must create it.
        dir.appendingPathComponent("store/bin/watchtower").path
    }

    private func makeStoreDir(for store: String) throws {
        try FileManager.default.createDirectory(
            atPath: (store as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
    }

    // MARK: sync

    func testFirstInstallCopiesWithoutStoppingDaemon() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        var stopped = false
        let outcome = await CLIBinaryStore.sync(
            bundleBinary: bundle, storeBinary: store) { stopped = true }
        XCTAssertEqual(outcome, .installed)
        XCTAssertFalse(stopped, "no store file existed, nothing could be running from it")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: store))
        XCTAssertEqual(try String(contentsOfFile: store, encoding: .utf8), "v1")
    }

    func testMatchingHashIsNoOp() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        var stopped = false
        let outcome = await CLIBinaryStore.sync(
            bundleBinary: bundle, storeBinary: store) { stopped = true }
        XCTAssertEqual(outcome, .upToDate)
        XCTAssertFalse(stopped)
    }

    func testStaleCopyStopsDaemonAndReplaces() async throws {
        let bundle = try write("bundle-cli", "v2")
        let store = storePath()
        try makeStoreDir(for: store)
        try Data("v1".utf8).write(to: URL(fileURLWithPath: store))
        var stopped = false
        let outcome = await CLIBinaryStore.sync(
            bundleBinary: bundle, storeBinary: store) { stopped = true }
        XCTAssertEqual(outcome, .replaced)
        XCTAssertTrue(stopped, "a stale store copy may back a live daemon — must stop before replacing")
        XCTAssertEqual(try String(contentsOfFile: store, encoding: .utf8), "v2")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: store))
    }

    /// The ordering is the whole point of the daemon stop: replacing the file
    /// first and stopping afterwards would leave a live process backed by a
    /// swapped inode. Read the store from inside the stop closure — it must
    /// still hold the old bytes there.
    func testDaemonIsStoppedBeforeTheFileIsSwapped() async throws {
        let bundle = try write("bundle-cli", "v2")
        let store = storePath()
        try makeStoreDir(for: store)
        try Data("v1".utf8).write(to: URL(fileURLWithPath: store))
        var contentSeenByStop: String?
        let outcome = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {
            contentSeenByStop = try? String(contentsOfFile: store, encoding: .utf8)
        }
        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(contentSeenByStop, "v1", "the swap must happen strictly after the daemon stop")
    }

    func testMissingBundleBinaryFailsAndLeavesStoreUntouched() async throws {
        let store = storePath()
        try makeStoreDir(for: store)
        try Data("v1".utf8).write(to: URL(fileURLWithPath: store))
        let outcome = await CLIBinaryStore.sync(
            bundleBinary: dir.appendingPathComponent("nope").path,
            storeBinary: store) {}
        guard case .failed = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertEqual(try String(contentsOfFile: store, encoding: .utf8), "v1")
    }

    /// Copy failure (here: the store's parent directory is a regular file, so
    /// neither createDirectory nor copyItem can succeed) must report `.failed`
    /// and leave whatever was there alone.
    func testCopyFailureReportsFailedAndLeavesStoreIntact() async throws {
        let bundle = try write("bundle-cli", "v2")
        let blockingFile = try write("blocked", "not a directory")
        let store = blockingFile + "/bin/watchtower"
        let outcome = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        guard case .failed = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertEqual(try String(contentsOfFile: blockingFile, encoding: .utf8), "not a directory")
    }

    /// Same bytes, lost exec bit: reporting `.upToDate` would leave a store
    /// copy nothing can run. Repair it instead.
    func testExecBitIsRepairedInsteadOfReportedUpToDate() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store)
        XCTAssertFalse(FileManager.default.isExecutableFile(atPath: store), "precondition")

        let outcome = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {
            XCTFail("nothing is being replaced — the daemon must not be stopped")
        }
        XCTAssertEqual(outcome, .upToDate)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: store))
    }

    /// A crash between copy and rename strands a `.watchtower-<pid>.tmp` file
    /// that nothing else ever removes.
    func testSyncSweepsStaleTemporaries() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        try makeStoreDir(for: store)
        let storeDir = (store as NSString).deletingLastPathComponent
        let litter = storeDir + "/.watchtower-99999.tmp"
        try Data("half-copied".utf8).write(to: URL(fileURLWithPath: litter))

        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: litter))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: store))
    }

    // MARK: installedPath

    func testInstalledPathNilWhenMissing() throws {
        let bundle = try write("bundle-cli", "v1")
        XCTAssertNil(CLIBinaryStore.installedPath(storeBinary: storePath(), bundleBinary: bundle))
    }

    func testInstalledPathReturnsValidatedCopy() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        XCTAssertEqual(CLIBinaryStore.installedPath(storeBinary: store, bundleBinary: bundle), store)
    }

    /// The store lives in a user-writable directory: a copy that does not match
    /// the bundled CLI must never be executed, whatever put it there. Callers
    /// fall back to the bundle.
    func testInstalledPathRejectsCopyThatDoesNotMatchTheBundle() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        // Same length as "v1", so this is caught by the hash, not the size.
        try Data("XX".utf8).write(to: URL(fileURLWithPath: store))
        XCTAssertNil(CLIBinaryStore.installedPath(storeBinary: store, bundleBinary: bundle))
    }

    func testInstalledPathRejectsCopyOfADifferentSize() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        try Data("a much longer build".utf8).write(to: URL(fileURLWithPath: store))
        XCTAssertNil(CLIBinaryStore.installedPath(storeBinary: store, bundleBinary: bundle))
    }

    func testInstalledPathRejectsNonExecutableCopy() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store)
        XCTAssertNil(CLIBinaryStore.installedPath(storeBinary: store, bundleBinary: bundle))
    }

    /// `swift run` / `swift test` have no bundled CLI. A store copy left by a
    /// past `make app` must not shadow the developer's PATH binary — there is
    /// nothing to validate it against.
    func testInstalledPathIgnoresStoreWhenThereIsNoBundledCLI() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: store), "precondition")
        XCTAssertNil(CLIBinaryStore.installedPath(storeBinary: store, bundleBinary: nil))
    }
}

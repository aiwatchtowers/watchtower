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
        try FileManager.default.createDirectory(
            atPath: (store as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try Data("v1".utf8).write(to: URL(fileURLWithPath: store))
        var stopped = false
        let outcome = await CLIBinaryStore.sync(
            bundleBinary: bundle, storeBinary: store) { stopped = true }
        XCTAssertEqual(outcome, .replaced)
        XCTAssertTrue(stopped, "a stale store copy may back a live daemon — must stop before replacing")
        XCTAssertEqual(try String(contentsOfFile: store, encoding: .utf8), "v2")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: store))
    }

    func testMissingBundleBinaryFailsAndLeavesStoreUntouched() async throws {
        let store = storePath()
        try FileManager.default.createDirectory(
            atPath: (store as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try Data("v1".utf8).write(to: URL(fileURLWithPath: store))
        let outcome = await CLIBinaryStore.sync(
            bundleBinary: dir.appendingPathComponent("nope").path,
            storeBinary: store) {}
        guard case .failed = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertEqual(try String(contentsOfFile: store, encoding: .utf8), "v1")
    }

    func testInstalledPathNilWhenMissing() {
        XCTAssertNil(CLIBinaryStore.installedPath(storeBinary: storePath()))
    }

    func testInstalledPathReturnsExecutableCopy() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        XCTAssertEqual(CLIBinaryStore.installedPath(storeBinary: store), store)
    }
}

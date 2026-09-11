import XCTest
@testable import WatchtowerCore

/// `startDaemon` runs `sync --daemon --detach`, which rejects an unusable
/// config.yaml before the daemon ever opens daemon.log. The CLI's stderr is
/// then the only diagnostic, so the Settings error line must carry it
/// instead of a bare exit code over an empty log.
final class DaemonManagerStartTests: XCTestCase {
    private var scriptPath: String!

    override func tearDownWithError() throws {
        if let scriptPath { try? FileManager.default.removeItem(atPath: scriptPath) }
    }

    private func makeScript(_ body: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-start-\(UUID().uuidString).sh").path
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        scriptPath = path
        return path
    }

    @MainActor
    func testFailedStartSurfacesCLIStderr() async throws {
        let script = try makeScript("echo 'workspace \"acme\" not found in config' >&2\nexit 1")
        let manager = DaemonManager()
        manager.watchtowerPath = script

        await manager.startDaemon()

        XCTAssertFalse(manager.isRunning)
        XCTAssertEqual(
            manager.errorMessage,
            "Failed to start daemon (exit code 1): workspace \"acme\" not found in config"
        )
    }

    /// A CLI that fails silently still reports the exit code — no dangling
    /// colon, no empty detail.
    @MainActor
    func testFailedStartWithoutStderrKeepsBareExitCode() async throws {
        let script = try makeScript("exit 3")
        let manager = DaemonManager()
        manager.watchtowerPath = script

        await manager.startDaemon()

        XCTAssertEqual(manager.errorMessage, "Failed to start daemon (exit code 3)")
    }

    @MainActor
    func testSuccessfulStartClearsError() async throws {
        let script = try makeScript("echo 'ignored noise' >&2\nexit 0")
        let manager = DaemonManager()
        manager.watchtowerPath = script
        manager.errorMessage = "stale"

        await manager.startDaemon()

        XCTAssertTrue(manager.isRunning)
        XCTAssertNil(manager.errorMessage)
    }

    func testStartFailureMessageTrimsStderr() {
        XCTAssertEqual(
            DaemonManager.startFailureMessage(status: 1, stderr: "  boom \n\n"),
            "Failed to start daemon (exit code 1): boom"
        )
        XCTAssertEqual(
            DaemonManager.startFailureMessage(status: 1, stderr: " \n"),
            "Failed to start daemon (exit code 1)"
        )
    }
}

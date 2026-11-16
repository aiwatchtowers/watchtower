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

    /// `notRunningSince` (readiness' daemon-down grace): nil before any
    /// status, set by the first "not running", kept across repeated polls,
    /// cleared when the daemon runs.
    @MainActor
    func testNotRunningSinceTracksDownStretch() {
        let manager = DaemonManager()
        XCTAssertNil(manager.notRunningSince)
        manager.isRunning = false
        let since = manager.notRunningSince
        XCTAssertNotNil(since)
        manager.isRunning = false
        XCTAssertEqual(manager.notRunningSince, since, "a repeated poll keeps the first moment")
        manager.isRunning = true
        XCTAssertNil(manager.notRunningSince)
    }

    /// Only a flip is reported: a poll that merely sees the same daemon
    /// again must not clear a restart failure on the banner.
    @MainActor
    func testOnlyFlipsAreReported() {
        let manager = DaemonManager()
        var reports: [Bool] = []
        manager.onRunningChanged = { reports.append($0) }
        manager.isRunning = true
        manager.isRunning = true
        manager.isRunning = false
        manager.isRunning = false
        XCTAssertEqual(reports, [true, false])
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

    /// A child that writes far more than a pipe buffer (64 KB) to stderr must
    /// not deadlock: the pipe is drained before `waitUntilExit`. Swapping the
    /// two calls hangs this test instead of passing it.
    @MainActor
    func testFailedStartDrainsLargeStderr() async throws {
        let script = try makeScript("head -c 300000 /dev/zero | tr '\\0' 'x' >&2\nexit 1")
        let manager = DaemonManager()
        manager.watchtowerPath = script

        await manager.startDaemon()

        let message = manager.errorMessage ?? ""
        XCTAssertTrue(message.hasPrefix("Failed to start daemon (exit code 1): xxx"), String(message.prefix(60)))
        XCTAssertGreaterThan(message.count, 200_000)
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

    // MARK: - --no-sync

    /// A process factory that records the arguments and runs `true`.
    private static func recording(_ seen: SeenArguments) -> (String, [String]) -> Process {
        { _, arguments in
            seen.value = arguments
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            process.standardOutput = FileHandle.nullDevice
            return process
        }
    }

    /// The app's start before onboarding finishes (mobile Inbox spec §3).
    func testNoSyncStartPassesTheFlag() async throws {
        let seen = SeenArguments()
        let result = try await DaemonManager.launchDetachedDaemon(
            path: "/usr/bin/true", noSync: true, loginEnvironment: { nil }, processFactory: Self.recording(seen)
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(seen.value, ["sync", "--daemon", "--detach", "--no-sync"])
    }

    func testDefaultStartHasNoFlag() async throws {
        let defaulted = SeenArguments()
        _ = try await DaemonManager.launchDetachedDaemon(
            path: "/usr/bin/true", loginEnvironment: { nil }, processFactory: Self.recording(defaulted)
        )
        XCTAssertEqual(defaulted.value, ["sync", "--daemon", "--detach"])
        let explicit = SeenArguments()
        _ = try await DaemonManager.launchDetachedDaemon(
            path: "/usr/bin/true", noSync: false, loginEnvironment: { nil }, processFactory: Self.recording(explicit)
        )
        XCTAssertEqual(explicit.value, ["sync", "--daemon", "--detach"])
    }
}

private final class SeenArguments: @unchecked Sendable {
    var value: [String] = []
}

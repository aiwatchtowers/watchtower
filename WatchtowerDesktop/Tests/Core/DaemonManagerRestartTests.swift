import XCTest
@testable import WatchtowerCore

/// `restart()` must never start a second daemon next to a live one: after a
/// `sync stop` that returned non-zero (the daemon did not exit within its
/// 10 s SIGTERM grace — normal while an AI call is in flight), it polls pid
/// liveness up to `restartStopGrace` before attempting `--detach`. The poll
/// itself is a pure loop over an injected `isAlive` closure, so it is pinned
/// here without spawning any process — the process-spawning half of
/// `restart()` stays untested per house precedent (see
/// `DaemonManagerStopTests`/`DaemonManagerStartTests` for why: it would need
/// a real `daemon.pid` under `Constants.databasePath`, a global this type has
/// no test seam for).
final class DaemonManagerRestartTests: XCTestCase {
    func testDiesAtStepThreeProceeds() async {
        var calls = 0
        let outcome = await DaemonManager.waitForPidDeath(
            isAlive: {
                calls += 1
                return calls < 3
            },
            step: .milliseconds(1),
            deadline: .seconds(60)
        )

        XCTAssertEqual(outcome, .died)
        XCTAssertEqual(calls, 3, "must stop polling the instant isAlive reports death")
    }

    func testNeverDiesTimesOut() async {
        let outcome = await DaemonManager.waitForPidDeath(
            isAlive: { true },
            step: .milliseconds(1),
            deadline: .milliseconds(20)
        )

        XCTAssertEqual(outcome, .timedOut)
    }

    /// The degenerate arm: already dead on the very first check must return
    /// immediately, never sleeping once.
    func testAlreadyDeadReturnsImmediately() async {
        let elapsed = await ContinuousClock().measure {
            _ = await DaemonManager.waitForPidDeath(
                isAlive: { false },
                step: .seconds(60),
                deadline: .seconds(60)
            )
        }

        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testStopTimedOutMessageNamesThePid() {
        let message = DaemonRestartError.stopTimedOut(pid: 4242).errorDescription ?? ""
        XCTAssertTrue(message.contains("4242"), message)
    }

    func testStopTimedOutMessageToleratesUnknownPid() {
        let message = DaemonRestartError.stopTimedOut(pid: nil).errorDescription ?? ""
        XCTAssertFalse(message.isEmpty)
    }

    func testStartFailedMessageMatchesStartFailureMessage() {
        XCTAssertEqual(
            DaemonRestartError.startFailed(status: 1, stderr: "boom").errorDescription,
            DaemonManager.startFailureMessage(status: 1, stderr: "boom")
        )
    }

    func testCLINotFoundHasAMessage() {
        XCTAssertFalse((DaemonRestartError.cliNotFound.errorDescription ?? "").isEmpty)
    }
}

// MARK: - livePID(atPath:)

/// `livePID` is the parsing routine `restart()`'s pid wait actually depends
/// on (via `activeWorkspaceDaemonPID`, scoped to the active workspace only —
/// F1 fix: the previous broad, all-workspaces scan could see a stale pid in
/// an unrelated worktree workspace and spin the full `restartStopGrace` for
/// nothing). Pinned here against a temp file, no `Constants.databasePath`
/// involved.
final class DaemonManagerLivePIDTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-livepid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func writePIDFile(_ contents: String) throws -> String {
        let path = tempDir.appendingPathComponent("daemon.pid").path
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    func testLiveProcessInPIDTimestampFormatReturnsThePid() throws {
        let myPid = ProcessInfo.processInfo.processIdentifier
        let path = try writePIDFile("\(myPid) 1234567890")

        XCTAssertEqual(DaemonManager.livePID(atPath: path), myPid)
    }

    func testDeadProcessReturnsNil() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 0"]
        try process.run()
        process.waitUntilExit()
        let deadPid = process.processIdentifier

        let path = try writePIDFile("\(deadPid)")

        XCTAssertNil(DaemonManager.livePID(atPath: path))
    }

    func testMissingFileReturnsNil() {
        let path = tempDir.appendingPathComponent("daemon.pid").path
        XCTAssertNil(DaemonManager.livePID(atPath: path))
    }

    func testGarbageContentsReturnsNil() throws {
        let path = try writePIDFile("not-a-pid")

        XCTAssertNil(DaemonManager.livePID(atPath: path))
    }
}

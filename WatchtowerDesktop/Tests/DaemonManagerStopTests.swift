import XCTest
@testable import WatchtowerDesktop

/// `stopDaemonBounded` is the one daemon stop both the quit path and the
/// launch-time CLI-store sync depend on, so its bound is the contract: it must
/// return, and it must not leave the child it spawned behind.
final class DaemonManagerStopTests: XCTestCase {
    private var scriptPath: String!
    private var pidFile: String!

    override func tearDownWithError() throws {
        if let scriptPath { try? FileManager.default.removeItem(atPath: scriptPath) }
        if let pidFile { try? FileManager.default.removeItem(atPath: pidFile) }
    }

    /// Writes an executable shell script. `exec` matters on the hung script:
    /// `sh` does not forward SIGTERM to a child, so without it `terminate()`
    /// would kill the shell and orphan the sleeper.
    private func makeScript(_ body: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-stop-\(UUID().uuidString).sh").path
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        scriptPath = path
        return path
    }

    func testHungSubprocessIsBoundedAndLeavesNoChildBehind() async throws {
        let pidPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-stop-pid-\(UUID().uuidString)").path
        pidFile = pidPath
        // `$$` survives the exec, so the recorded pid IS the sleeping process.
        let script = try makeScript("echo $$ > \(pidPath)\nexec sleep 100")

        let elapsed = await ContinuousClock().measure {
            await DaemonManager.stopDaemonBounded(timeout: .seconds(2), cliPath: script)
        }

        // The watchdog is deliberately generous: on a loaded machine (the full
        // suite) a shorter one fires before `sh` has even reached its first
        // line, and the pid assertion below then has nothing to read. What the
        // bound has to prove is that the caller is released nowhere near the
        // script's 100 s, not that it is released in milliseconds.
        XCTAssertLessThan(elapsed, .seconds(6), "a hung `sync stop` must not hold the caller")

        let recorded = try String(contentsOfFile: pidPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(pid_t(recorded))
        XCTAssertNotEqual(kill(pid, 0), 0, "the terminated child must be gone, not left running")
    }

    /// The degenerate arm of the same loop: a `sync stop` that finishes
    /// immediately must be awaited for as long as it actually takes, not for
    /// the watchdog's timeout.
    func testFastExitReturnsWellBeforeTheTimeout() async throws {
        let script = try makeScript("exit 0")

        let elapsed = await ContinuousClock().measure {
            await DaemonManager.stopDaemonBounded(timeout: .seconds(12), cliPath: script)
        }

        XCTAssertLessThan(elapsed, .seconds(1), "a prompt stop must not wait out the watchdog")
    }

    /// No CLI resolved (dev run without the binary): nothing to spawn, nothing
    /// to wait for.
    func testMissingCLIPathIsANoOp() async {
        let elapsed = await ContinuousClock().measure {
            await DaemonManager.stopDaemonBounded(timeout: .seconds(12), cliPath: nil)
        }
        XCTAssertLessThan(elapsed, .milliseconds(500))
    }
}

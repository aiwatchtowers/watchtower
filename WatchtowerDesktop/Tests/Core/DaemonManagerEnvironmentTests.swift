import XCTest
@testable import WatchtowerCore

/// The daemon is launched with the owner's login-shell `CODEX_HOME` (and
/// nothing else from the login environment), from both launch sites.
final class DaemonManagerEnvironmentTests: XCTestCase {
    func testDaemonEnvCarriesLoginCodexHome() {
        let env = DaemonManager.daemonEnvironment(
            base: ["PATH": "/usr/bin"],
            login: ["CODEX_HOME": "/tmp/x/codex", "PATH": "/opt/bin"]
        )
        XCTAssertEqual(env["CODEX_HOME"], "/tmp/x/codex")
        XCTAssertEqual(env["PATH"], "/usr/bin")
    }

    func testDaemonEnvIgnoresMissingRelativeOrUnansweredLogin() {
        let base = ["PATH": "/usr/bin"]
        XCTAssertNil(DaemonManager.daemonEnvironment(base: base, login: ["PATH": "/x"])["CODEX_HOME"])
        XCTAssertNil(DaemonManager.daemonEnvironment(base: base, login: ["CODEX_HOME": "rel/codex"])["CODEX_HOME"])
        XCTAssertEqual(DaemonManager.daemonEnvironment(base: base, login: nil), base)
    }

    func testDaemonEnvKeepsBaseCodexHomeWhenLoginHasNone() {
        let env = DaemonManager.daemonEnvironment(base: ["CODEX_HOME": "/base/codex"], login: nil)
        XCTAssertEqual(env["CODEX_HOME"], "/base/codex")
    }

    /// Both `startDaemon()` and `restart()` call `launchDetachedDaemon`; this
    /// pins the arguments; the next test pins the environment.
    func testDetachedLaunchPassesDaemonArguments() async throws {
        var seenArguments: [String] = []
        let result = try await DaemonManager.launchDetachedDaemon(
            path: "/usr/bin/true",
            loginEnvironment: { ["CODEX_HOME": "/tmp/x/codex", "PATH": "/opt/bin"] },
            processFactory: { _, arguments in
                seenArguments = arguments
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
                process.standardOutput = FileHandle.nullDevice
                return process
            }
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(seenArguments, ["sync", "--daemon", "--detach"])
    }

    func testDetachedLaunchChildSeesLoginCodexHome() async throws {
        let result = try await DaemonManager.launchDetachedDaemon(
            path: "/bin/sh",
            loginEnvironment: { ["CODEX_HOME": "/tmp/x/codex"] },
            processFactory: { _, _ in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                // Exit 0 only when the child sees the login's CODEX_HOME.
                process.arguments = ["-c", "[ \"$CODEX_HOME\" = /tmp/x/codex ]"]
                process.standardOutput = FileHandle.nullDevice
                return process
            }
        )
        XCTAssertEqual(result.status, 0)
    }
}

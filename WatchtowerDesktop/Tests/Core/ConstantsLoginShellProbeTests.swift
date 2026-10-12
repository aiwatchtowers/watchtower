import XCTest
@testable import WatchtowerCore

/// `Constants.resolvedEnvironment`'s login-shell probe (board #399, spec
/// 2026-10-12 §7): PATH and the login shell's CODEX_HOME, read back past
/// whatever the shell's startup files print.
final class ConstantsLoginShellProbeTests: XCTestCase {
    func testParsesPathAndCodexHomePastNoise() {
        let output = """
            Welcome back!
            WATCHTOWER_PROBE_PATH=/opt/homebrew/bin:/usr/bin
            WATCHTOWER_PROBE_CODEX_HOME=/Users/example/.codex-work
            """
        let probed = Constants.parseLoginShellProbe(output)
        XCTAssertEqual(probed.path, "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(probed.codexHome, "/Users/example/.codex-work")
    }

    func testEmptyOrMissingValuesAreNil() {
        let unset = Constants.parseLoginShellProbe("WATCHTOWER_PROBE_PATH=/usr/bin\nWATCHTOWER_PROBE_CODEX_HOME=\n")
        XCTAssertEqual(unset.path, "/usr/bin")
        XCTAssertNil(unset.codexHome, "an unset CODEX_HOME leaves the app's own")

        for output in ["", "\n", "/usr/bin\n", "garbage"] {
            let probed = Constants.parseLoginShellProbe(output)
            XCTAssertNil(probed.path, output)
            XCTAssertNil(probed.codexHome, output)
        }
    }

    /// The probe command itself, run by shells without startup files: the
    /// values come back verbatim, spaces included.
    func testProbeRunsUnderShAndZsh() throws {
        for (shell, flag) in [("/bin/sh", "-c"), ("/bin/zsh", "-fc")] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = [flag, Constants.loginShellProbe]
            process.environment = ["PATH": "/usr/bin:/bin:/Users/example/my tools", "CODEX_HOME": "/Users/example/codex home"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let probed = Constants.parseLoginShellProbe(output)
            XCTAssertEqual(probed.path, "/usr/bin:/bin:/Users/example/my tools", shell)
            XCTAssertEqual(probed.codexHome, "/Users/example/codex home", shell)
        }
    }
}

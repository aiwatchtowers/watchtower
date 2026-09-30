import XCTest
@testable import WatchtowerCore

final class ProjectTerminalLaunchTests: XCTestCase {
    func testLoginShellExecsClaudeInTheFolder() {
        let launch = ProjectTerminalLaunch.make(shell: "/bin/bash", folder: "/tmp/acme dir", firstRun: false)
        XCTAssertEqual(launch.executable, "/bin/bash")
        XCTAssertEqual(launch.args, ["-l", "-c", "exec claude"])
        XCTAssertEqual(launch.currentDirectory, "/tmp/acme dir")
    }

    func testFirstRunPassesTheFixedSetupPromptSingleQuoted() {
        let launch = ProjectTerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp/acme", firstRun: true)
        XCTAssertEqual(launch.args, [
            "-l", "-c", "exec claude 'Set up this Watchtower project using the watchtower-project skill.'"
        ])
        // The prompt is fixed text: no owner data, and nothing the single
        // quotes would need escaping for.
        XCTAssertFalse(ProjectTerminalLaunch.firstRunPrompt.contains("'"))
    }

    func testMissingOrRelativeShellFallsBackToZsh() {
        XCTAssertEqual(ProjectTerminalLaunch.make(shell: nil, folder: "/tmp", firstRun: false).executable, "/bin/zsh")
        XCTAssertEqual(ProjectTerminalLaunch.make(shell: "", folder: "/tmp", firstRun: false).executable, "/bin/zsh")
        XCTAssertEqual(ProjectTerminalLaunch.make(shell: "zsh", folder: "/tmp", firstRun: false).executable, "/bin/zsh")
    }

    func testExitMessageNamesAMissingClaudeForCommandNotFound() {
        XCTAssertTrue(ProjectTerminalLaunch.exitMessage(code: 127).contains("not found on your login-shell PATH"))
        XCTAssertEqual(ProjectTerminalLaunch.exitMessage(code: 1), "Claude Code exited (code 1).")
        XCTAssertEqual(ProjectTerminalLaunch.exitMessage(code: nil), "Claude Code exited.")
    }
}

import XCTest
@testable import WatchtowerCore

final class TerminalLaunchTests: XCTestCase {
    private let uuid = "3f2a1b4c-0000-4000-8000-000000000001"

    func testNewClaudeWithPromptQuotesPromptAndPassesSessionID() {
        let prompt = TerminalLaunch.workOnTargetPrompt(targetID: 42)
        let l = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp/acme", mode: .newClaude(uuid: uuid, prompt: prompt))
        let command = "exec claude --session-id \(uuid) 'Work on target #42 using the watchtower-project skill.'"
        XCTAssertEqual(l.args, ["-l", "-c", command])
        XCTAssertEqual(l.currentDirectory, "/tmp/acme")
    }

    func testNewClaudeWithoutPrompt() {
        let l = TerminalLaunch.make(shell: "/bin/bash", folder: "/tmp/acme dir", mode: .newClaude(uuid: uuid, prompt: nil))
        XCTAssertEqual(l.executable, "/bin/bash")
        XCTAssertEqual(l.args, ["-l", "-c", "exec claude --session-id \(uuid)"])
        XCTAssertEqual(l.currentDirectory, "/tmp/acme dir")
    }

    func testResume() {
        let l = TerminalLaunch.make(shell: nil, folder: "/tmp/acme", mode: .resumeClaude(uuid: uuid))
        XCTAssertEqual(l.executable, "/bin/zsh")
        XCTAssertEqual(l.args.last, "exec claude --resume \(uuid)")
    }

    func testShellIsPlainLoginShell() {
        XCTAssertEqual(TerminalLaunch.make(shell: "/bin/bash", folder: "/tmp", mode: .shell).args, ["-l"])
    }

    func testFirstRunKeepsTheSetupPrompt() {
        let prompt = TerminalLaunch.firstRunPrompt
        let l = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp/acme", mode: .newClaude(uuid: uuid, prompt: prompt))
        XCTAssertEqual(l.args.last?.hasSuffix("'\(prompt)'"), true)
    }

    func testSessionIDValidation() {
        XCTAssertTrue(TerminalLaunch.isValidSessionID(uuid))
        XCTAssertFalse(TerminalLaunch.isValidSessionID("3F2A1B4C-0000-4000-8000-000000000001"))
        XCTAssertFalse(TerminalLaunch.isValidSessionID("x; rm -rf ~"))
        XCTAssertFalse(TerminalLaunch.isValidSessionID("\(uuid)\n"))
        XCTAssertFalse(TerminalLaunch.isValidSessionID(""))
    }

    func testFixedPromptsHoldNoQuote() {
        XCTAssertFalse(TerminalLaunch.firstRunPrompt.contains("'"))
        XCTAssertFalse(TerminalLaunch.workOnTargetPrompt(targetID: 9_223_372_036_854_775_807).contains("'"))
    }

    func testMissingOrRelativeShellFallsBackToZsh() {
        XCTAssertEqual(TerminalLaunch.make(shell: nil, folder: "/tmp", mode: .shell).executable, "/bin/zsh")
        XCTAssertEqual(TerminalLaunch.make(shell: "", folder: "/tmp", mode: .shell).executable, "/bin/zsh")
        XCTAssertEqual(TerminalLaunch.make(shell: "zsh", folder: "/tmp", mode: .shell).executable, "/bin/zsh")
    }

    func testExitMessageNamesAMissingClaudeForCommandNotFound() {
        XCTAssertTrue(TerminalLaunch.exitMessage(code: 127).contains("not found on your login-shell PATH"))
        XCTAssertEqual(TerminalLaunch.exitMessage(code: 1), "Claude Code exited (code 1).")
        XCTAssertEqual(TerminalLaunch.exitMessage(code: nil), "Claude Code exited.")
    }
}

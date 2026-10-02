import XCTest
@testable import WatchtowerCore

final class TerminalLaunchTests: XCTestCase {
    private let uuid = "3f2a1b4c-0000-4000-8000-000000000001"

    func testNewClaudeWithPromptQuotesPromptAndPassesSessionID() {
        let prompt = TerminalLaunch.workOnTargetPrompt(targetID: 42, vocabulary: .current)
        let l = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp/acme", mode: .newClaude(uuid: uuid, prompt: prompt))
        let command = "exec claude --session-id \(uuid) 'Work on target #42 using the watchtower-workbench skill.'"
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

    /// A claude launch names its row for the project's SessionStart hook
    /// (board #160); a shell runs no hook and gets nothing.
    func testClaudeLaunchCarriesTheRowIDInItsEnvironment() {
        let env = ["\(TerminalLaunch.sessionRowEnv)=7"]
        XCTAssertEqual(TerminalLaunch.sessionRowEnv, "WATCHTOWER_TERMINAL_SESSION_ID", "Go terminalSessionEnv")
        XCTAssertEqual(TerminalLaunch.make(shell: nil, folder: "/tmp", mode: .newClaude(uuid: uuid, prompt: nil), rowID: 7).environment, env)
        XCTAssertEqual(TerminalLaunch.make(shell: nil, folder: "/tmp", mode: .resumeClaude(uuid: uuid), rowID: 7).environment, env)
        XCTAssertEqual(TerminalLaunch.make(shell: nil, folder: "/tmp", mode: .shell, rowID: 7).environment, [])
        XCTAssertEqual(TerminalLaunch.make(shell: nil, folder: "/tmp", mode: .resumeClaude(uuid: uuid)).environment, [])
    }

    func testShellIsPlainLoginShell() {
        XCTAssertEqual(TerminalLaunch.make(shell: "/bin/bash", folder: "/tmp", mode: .shell).args, ["-l"])
    }

    func testFirstRunKeepsTheSetupPrompt() {
        let prompt = TerminalLaunch.firstRunPrompt(.current)
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
        for vocabulary in [WorkbenchVocabulary.current, .legacy] {
            XCTAssertFalse(TerminalLaunch.firstRunPrompt(vocabulary).contains("'"))
            XCTAssertFalse(TerminalLaunch.workOnTargetPrompt(targetID: 9_223_372_036_854_775_807, vocabulary: vocabulary).contains("'"))
        }
    }

    /// A folder set up before the Workbench rename has only the old skill
    /// (spec 2026-10-02 §5.3); the prompts name what the folder has, and stay
    /// one line without control characters.
    func testPromptsNameTheFoldersSkill() {
        XCTAssertEqual(TerminalLaunch.firstRunPrompt(.current),
                       "Set up this Watchtower workbench using the watchtower-workbench skill.")
        XCTAssertEqual(TerminalLaunch.firstRunPrompt(.legacy),
                       "Set up this Watchtower workbench using the watchtower-project skill.")
        XCTAssertEqual(TerminalLaunch.workOnTargetPrompt(targetID: 7, vocabulary: .current),
                       "Work on target #7 using the watchtower-workbench skill.")
        XCTAssertEqual(TerminalLaunch.workOnTargetPrompt(targetID: 7, vocabulary: .legacy),
                       "Work on target #7 using the watchtower-project skill.")
        for vocabulary in [WorkbenchVocabulary.current, .legacy] {
            for prompt in [TerminalLaunch.firstRunPrompt(vocabulary), TerminalLaunch.workOnTargetPrompt(targetID: 7, vocabulary: vocabulary)] {
                XCTAssertFalse(prompt.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) })
            }
        }
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

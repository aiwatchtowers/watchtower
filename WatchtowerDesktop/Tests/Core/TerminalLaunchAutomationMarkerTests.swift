import XCTest
@testable import WatchtowerCore

/// AGENT-07 (automations P5): an agent session an automation run started
/// carries `WATCHTOWER_AUTOMATION_RUN_ID` on every launch of its row, a
/// resume included, so the CLI refuses owner-only writes from it.
final class TerminalLaunchAutomationMarkerTests: XCTestCase {
    private let uuid = "3f2a1b4c-0000-4000-8000-000000000001"
    private let codex = CodexLaunchArgs(binary: "/usr/local/bin/codex", pathPrepend: "", args: [])

    func testNewAgentLaunchCarriesRunMarker() {
        let claude = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp/acme",
                                         mode: .newClaude(uuid: uuid, prompt: "Review PR 7"), rowID: 4, automationRunID: 12)
        XCTAssertEqual(claude.environment, ["WATCHTOWER_TERMINAL_SESSION_ID=4", "WATCHTOWER_FIRST_PROMPT=Review PR 7",
                                            "WATCHTOWER_AUTOMATION_RUN_ID=12"])
        let codexLaunch = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp/acme",
                                              mode: .newAgent(.codex, sessionID: nil, prompt: nil), rowID: 4,
                                              codex: codex, automationRunID: 12)
        XCTAssertEqual(codexLaunch.environment.last, "WATCHTOWER_AUTOMATION_RUN_ID=12")
    }

    func testResumeCarriesRunMarker() {
        let resumed = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp/acme", mode: .resumeClaude(uuid: uuid),
                                          rowID: 4, automationRunID: 12)
        XCTAssertEqual(resumed.args, ["-l", "-c", "exec claude --resume \(uuid)"])
        XCTAssertEqual(resumed.environment, ["WATCHTOWER_TERMINAL_SESSION_ID=4", "WATCHTOWER_AUTOMATION_RUN_ID=12"])
    }

    func testNoMarkerWithoutRun() {
        let new = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp/acme", mode: .newClaude(uuid: uuid, prompt: nil),
                                      rowID: 4)
        XCTAssertEqual(new.environment, ["WATCHTOWER_TERMINAL_SESSION_ID=4"])
    }

    func testShellLaunchNeverCarriesMarker() {
        let shell = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp/acme", mode: .shell, rowID: 4, automationRunID: 12)
        XCTAssertEqual(shell.environment, [])
    }

    /// The name is the one the CLI's agent markers list (Go `RunEnvMarker`).
    func testMarkerNameIsAnAgentMarker() {
        XCTAssertTrue(Constants.agentEnvMarkers.contains(TerminalLaunch.automationRunEnv))
    }
}

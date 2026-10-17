import XCTest
@testable import WatchtowerCore

/// The app's resolved environment drops every marker of an AI agent's shell
/// (Go `agentEnvMarkers`, cmd/owner_confirm.go): launched from Claude Code, Codex
/// or a workbench terminal, the app's own `watchtower actions approve` would
/// otherwise be refused as if an agent ran it (AGENT-07).
final class ConstantsAgentMarkersTests: XCTestCase {
    func testEveryAgentMarkerIsDropped() {
        let env = [
            "PATH": "/usr/bin", "HOME": "/Users/example",
            "CLAUDECODE": "1", "CODEX_THREAD_ID": "t-1", "CODEX_SANDBOX": "seatbelt",
            "WATCHTOWER_TERMINAL_SESSION_ID": "42", "WATCHTOWER_AUTOMATION_RUN_ID": "7"
        ]
        XCTAssertEqual(Constants.withoutAgentMarkers(env), ["PATH": "/usr/bin", "HOME": "/Users/example"])
    }

    func testMarkersMatchTheGoListAndTheTerminalVariable() {
        XCTAssertEqual(
            Constants.agentEnvMarkers,
            [
                "CLAUDECODE", "CODEX_THREAD_ID", "CODEX_SANDBOX", "WATCHTOWER_TERMINAL_SESSION_ID",
                "WATCHTOWER_AUTOMATION_RUN_ID"
            ]
        )
        XCTAssertTrue(Constants.agentEnvMarkers.contains(TerminalLaunch.sessionRowEnv))
    }
}

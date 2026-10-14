import XCTest
@testable import WatchtowerCore

/// The per-launch agent choice (board #399, D1).
final class AgentChoicePresentationTests: XCTestCase {
    func testNewSessionMenuListsBothAgentsDisablesMissing() {
        let both = AgentChoicePresentation.newSessionAgentChoices { _ in true }
        XCTAssertEqual(both.map(\.title), ["New Claude Code session", "New Codex session"])
        XCTAssertEqual(both.map(\.isAvailable), [true, true])
        XCTAssertEqual(both.map(\.hint), [nil, nil])

        let noCodex = AgentChoicePresentation.newSessionAgentChoices { $0 == .claude }
        XCTAssertEqual(noCodex.map(\.agent), [.claude, .codex], "a missing agent stays listed")
        XCTAssertEqual(noCodex[1].title, "New Codex session (not installed)")
        XCTAssertFalse(noCodex[1].isAvailable)
        XCTAssertEqual(noCodex[1].hint, "Codex was not found. Install it, or set codex_path in Watchtower's config.")

        let noClaude = AgentChoicePresentation.newSessionAgentChoices { $0 == .codex }
        XCTAssertFalse(noClaude[0].isAvailable)
        XCTAssertTrue(noClaude[0].hint?.contains("claude_path") == true)

        let none = AgentChoicePresentation.newSessionAgentChoices { _ in false }
        XCTAssertEqual(none.map(\.isAvailable), [false, false])
    }

    func testWorkOnMenuOffersTheOtherAgent() {
        XCTAssertEqual(AgentChoicePresentation.workOnOthers(defaultAgent: .claude) { _ in true }.map(\.title),
                       ["Work on It with Codex"])
        XCTAssertEqual(AgentChoicePresentation.workOnOthers(defaultAgent: .codex) { _ in true }.map(\.title),
                       ["Work on It with Claude Code"])
        let missing = AgentChoicePresentation.workOnOthers(defaultAgent: .claude) { _ in false }
        XCTAssertEqual(missing.map(\.title), ["Work on It with Codex (not installed)"])
        XCTAssertEqual(missing.map(\.isAvailable), [false])
    }

    /// Strings per agent: nothing on a Codex path names Claude Code, and the
    /// Claude Code wording is what it always was.
    func testNoClaudeCodeStringOnCodexPaths() {
        let codexStrings = [
            AgentChoicePresentation.workOnHelp(existing: nil, defaultAgent: .codex),
            AgentChoicePresentation.workOnHelp(existing: .codex, defaultAgent: .claude),
            AgentChoicePresentation.deleteSessionMessage(.codex),
            AgentChoicePresentation.notInstalledHint(.codex),
            TerminalLaunch.exitMessage(code: 127, agent: .codex),
            TerminalLaunch.exitMessage(code: 1, agent: .codex)
        ] + AgentChoicePresentation.newSessionAgentChoices { _ in false }.filter { $0.agent == .codex }.flatMap { [$0.title, $0.hint ?? ""] }
            + AgentChoicePresentation.workOnOthers(defaultAgent: .claude) { _ in false }.flatMap { [$0.title, $0.hint ?? ""] }
        for text in codexStrings {
            XCTAssertFalse(text.contains("Claude"), text)
            XCTAssertTrue(text.contains("Codex") || text.contains("codex"), text)
        }
        XCTAssertEqual(AgentChoicePresentation.workOnHelp(existing: nil, defaultAgent: .claude),
                       "Start a Claude Code session for this target")
        XCTAssertEqual(AgentChoicePresentation.workOnHelp(existing: .claude, defaultAgent: .codex),
                       "Open the Claude Code session for this target", "the session it opens names its own agent")
        XCTAssertEqual(AgentChoicePresentation.deleteSessionMessage(.claude),
                       "Its process stops and it leaves the list. Claude Code's own transcript is kept.")
        XCTAssertEqual(AgentChoicePresentation.deleteSessionMessage(.shell),
                       AgentChoicePresentation.deleteSessionMessage(.claude), "a shell keeps the old wording")
    }
}

import XCTest
@testable import WatchtowerCore

/// Spec 2026-10-12 §8 (board #399): how lines are typed into each agent.
final class AgentInputProfileTests: XCTestCase {
    /// Spec I1: Claude Code's delivery is byte-identical — a CR submit, no
    /// agent-specific newline, the 150 ms hand-off and 500 ms answer pauses
    /// of boards #379/#380.
    func testClaudeProfileBytesUnchanged() {
        let claude = AgentInputProfile.claude
        XCTAssertEqual(claude.submit, [0x0D])
        XCTAssertNil(claude.newline)
        XCTAssertEqual(claude.pasteSettle, .milliseconds(150))
        XCTAssertEqual(claude.submitSettle, .milliseconds(500))
        XCTAssertEqual(AgentInputProfile.for(.claude), .claude)
    }

    /// Task 0 capture: CR submits a bracketed paste, Ctrl+J (LF) inserts a
    /// line break; the pauses are Claude Code's (spec §8).
    func testCodexProfileIsCRSubmitWithCtrlJNewline() {
        let codex = AgentInputProfile.codex
        XCTAssertEqual(codex.submit, [0x0D])
        XCTAssertEqual(codex.newline, [0x0A])
        XCTAssertEqual(codex.pasteSettle, AgentInputProfile.claude.pasteSettle)
        XCTAssertEqual(codex.submitSettle, AgentInputProfile.claude.submitSettle)
        XCTAssertEqual(AgentInputProfile.for(.codex), .codex)
    }

    /// Every agent has a profile with a key that submits, a newline that is
    /// not that key (it would never read as a submit), and an answer pause
    /// no shorter than the hand-off's.
    func testEveryAgentHasAUsableProfile() {
        for kind in AgentKind.allCases {
            let profile = AgentInputProfile.for(kind)
            XCTAssertFalse(profile.submit.isEmpty, "\(kind)")
            XCTAssertNotEqual(profile.newline, profile.submit, "\(kind)")
            XCTAssertNotEqual(profile.newline, [], "\(kind): an empty newline would match every input")
            XCTAssertGreaterThan(profile.pasteSettle, .zero, "\(kind)")
            XCTAssertGreaterThanOrEqual(profile.submitSettle, profile.pasteSettle, "\(kind)")
        }
    }
}

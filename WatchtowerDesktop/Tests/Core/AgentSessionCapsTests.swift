import XCTest
@testable import WatchtowerCore

/// The Swift twin of Go's `agentkind.SessionCaps` (plan Task G7; A5's shared
/// fixture replaces both).
final class AgentSessionCapsTests: XCTestCase {
    /// The rows G7's spikes on codex 0.159.2 support, and Go's.
    func testRowsMatchGo() {
        XCTAssertEqual(AgentSessionCaps.of(AgentKind.claude), AgentSessionCaps(
            midturnInput: true, phoneInput: true, permissionWait: true, idleSignal: true, elicitation: true
        ))
        XCTAssertEqual(AgentSessionCaps.of(AgentKind.codex), AgentSessionCaps(
            midturnInput: true, phoneInput: true, permissionWait: false, idleSignal: false, elicitation: false,
            rolloutWatch: true
        ))
        XCTAssertFalse(AgentSessionCaps.of(AgentKind.claude).rolloutWatch, "Claude's StopFailure hook reports a failed turn")
    }

    /// Claude reports every mid-turn dialog; Codex's MCP forms raise no
    /// state, so nothing goes to it while it works and the phone sends it no Esc.
    func testDerivedGates() {
        XCTAssertTrue(AgentSessionCaps.of(AgentKind.claude).takesLineWhileWorking)
        XCTAssertTrue(AgentSessionCaps.of(AgentKind.claude).takesInterrupt)
        XCTAssertFalse(AgentSessionCaps.of(AgentKind.codex).takesLineWhileWorking)
        XCTAssertFalse(AgentSessionCaps.of(AgentKind.codex).takesInterrupt)
    }
}

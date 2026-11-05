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
            midturnInput: true, phoneInput: true, permissionWait: false, idleSignal: false, elicitation: false
        ))
        XCTAssertEqual(AgentSessionCaps.of(TerminalSession.Kind.shell), .none)
        XCTAssertEqual(AgentSessionCaps.of(nil as TerminalSession.Kind?), .none)
    }

    /// Both hubs type a phone line while the agent works (PROJ-16): a kind
    /// that takes phone input must take mid-turn input.
    func testPhoneInputImpliesMidturnInput() {
        for agent in AgentKind.allCases where AgentSessionCaps.of(agent).phoneInput {
            XCTAssertTrue(AgentSessionCaps.of(agent).midturnInput, agent.rawValue)
        }
    }
}

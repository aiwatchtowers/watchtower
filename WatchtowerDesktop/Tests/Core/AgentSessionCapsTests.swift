import XCTest
@testable import WatchtowerCore

/// The Swift twin of Go's `sessionagent.Caps`, pinned to the shared
/// `internal/sessionagent/agent_capabilities.json` (plan Task A5; WatchtowerCore
/// stays Kit-free, so it mirrors the rows and this test reads Go's fixture).
final class AgentSessionCapsTests: XCTestCase {
    /// Every row the Desktop decides by equals the Go adapters' fixture, and
    /// the fixture lists every agent kind.
    func testRowsMatchTheGoFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/sessionagent/agent_capabilities.json")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let agents = try XCTUnwrap(raw?["agents"] as? [String: [String: Any]])
        XCTAssertEqual(Set(agents.keys), Set(AgentKind.allCases.map(\.rawValue)))
        for kind in AgentKind.allCases {
            let row = try XCTUnwrap(agents[kind.rawValue], kind.rawValue)
            let caps = AgentSessionCaps.of(kind)
            XCTAssertEqual(row["midturn_input"] as? Bool, caps.midturnInput, kind.rawValue)
            XCTAssertEqual(row["phone_input"] as? Bool, caps.phoneInput, kind.rawValue)
            XCTAssertEqual(row["permission_wait"] as? Bool, caps.permissionWait, kind.rawValue)
            XCTAssertEqual(row["idle_signal"] as? Bool, caps.idleSignal, kind.rawValue)
            XCTAssertEqual(row["elicitation"] as? Bool, caps.elicitation, kind.rawValue)
            XCTAssertEqual((row["failure_signal"] as? String) == "pull", caps.rolloutWatch, kind.rawValue)
            XCTAssertEqual(row["launch_hooks"] as? Bool, caps.launchHooks, kind.rawValue)
            XCTAssertEqual(row["app_session_id"] as? Bool, caps.appSessionID, kind.rawValue)
            XCTAssertEqual(row["analytics_context"] as? Bool, caps.analyticsContext, kind.rawValue)
        }
    }

    /// The rows G7's spikes on codex 0.159.2 support, and Go's.
    func testRowsMatchGo() {
        XCTAssertEqual(AgentSessionCaps.of(AgentKind.claude), AgentSessionCaps(
            midturnInput: true, phoneInput: true, permissionWait: true, idleSignal: true, elicitation: true,
            appSessionID: true, analyticsContext: true
        ))
        XCTAssertEqual(AgentSessionCaps.of(AgentKind.codex), AgentSessionCaps(
            midturnInput: true, phoneInput: true, permissionWait: false, idleSignal: false, elicitation: false,
            rolloutWatch: true, launchHooks: true
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

    /// Analytics' caption names the agents whose transcripts record no
    /// context breakdown, from the capability rows; nil when every one does.
    func testContextNotMeasuredCaption() {
        XCTAssertEqual(AgentSessionCaps.contextNotMeasuredCaption(), "Not measured for Codex sessions.")
        let all = AgentSessionCaps(midturnInput: false, phoneInput: false, permissionWait: false, idleSignal: false,
                                   elicitation: false, analyticsContext: true)
        XCTAssertNil(AgentSessionCaps.contextNotMeasuredCaption { _ in all })
    }
}

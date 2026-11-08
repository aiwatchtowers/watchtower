/// The session capability rows reach the phone through the Kit's copy of the
/// Go session adapters' fixture (spec 2026-11-05 §3.5, the POLICY-02
/// dual-path style): the copy must equal Go's file byte for byte, and decode
/// to the rows Go's adapters report.
import Foundation
import WatchtowerKit
import XCTest

final class AgentSessionCapabilitiesTests: XCTestCase {
    private static let goFixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // WatchtowerKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerKit
        .deletingLastPathComponent() // repository root
        .appendingPathComponent("internal/sessionagent/agent_capabilities.json")

    private static let kitCopy = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/WatchtowerKit/Resources/agent_capabilities.json")

    func testDecodesGoFixture() throws {
        let go = try Data(contentsOf: Self.goFixture)
        XCTAssertEqual(try Data(contentsOf: Self.kitCopy), go,
                       "copy internal/sessionagent/agent_capabilities.json into the Kit's Resources")
        let table = try AgentSessionCapabilities.decode(go)
        XCTAssertEqual(AgentSessionCapabilities.bundled, table.agents, "the bundled resource is the fixture")
        XCTAssertEqual(Set(table.agents.keys), ["claude", "codex"])

        let claude = try XCTUnwrap(AgentSessionCapabilities.of("claude"))
        XCTAssertEqual(claude.failureSignal, "hook")
        XCTAssertTrue(claude.takesLineWhileWorking)
        XCTAssertTrue(claude.takesInterrupt)
        XCTAssertFalse(claude.rolloutWatch)

        let codex = try XCTUnwrap(AgentSessionCapabilities.of("codex"))
        XCTAssertTrue(codex.rolloutWatch)
        XCTAssertTrue(codex.phoneInput)
        XCTAssertFalse(codex.takesLineWhileWorking, "an MCP form opens with no hook state")
        XCTAssertFalse(codex.takesInterrupt)
        XCTAssertFalse(codex.idleSignal)
        XCTAssertTrue(claude.appSessionID)
        XCTAssertFalse(codex.appSessionID, "Codex mints its own session id")
        XCTAssertNil(AgentSessionCapabilities.of("shell"))
    }

    /// A7b: the phone half lists exactly the capability rows' kinds, each
    /// direction with what to do, so an agent kind Go adds fails here.
    func testPhoneCapsListExactlyTheCapabilityKinds() throws {
        let phoneCaps = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WatchtowerKitTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Fixtures/workbench/phone_caps.json")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: phoneCaps)) as? [String: Any]
        let phone = Set(try XCTUnwrap(raw?["agents"] as? [String: Any], "phone_caps.json has no agents").keys)
        let rows = Set(AgentSessionCapabilities.bundled.keys)
        XCTAssertFalse(rows.isEmpty, "the bundled agent_capabilities.json has no rows")
        XCTAssertTrue(rows.subtracting(phone).isEmpty,
                      "agent kind(s) \(rows.subtracting(phone).sorted()) have a capability row but no phone_caps.json row: "
                          + "regenerate it from Go (TestSessionAgent_PhoneCapsMatchKitFixture)")
        XCTAssertTrue(phone.subtracting(rows).isEmpty,
                      "phone_caps.json has kind(s) \(phone.subtracting(rows).sorted()) with no capability row: "
                          + "copy internal/sessionagent/agent_capabilities.json into the Kit's Resources")
    }

    /// Every key of every row is decoded: a key Go adds without the Kit fails.
    func testEveryFixtureKeyIsDecoded() throws {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.goFixture)) as? [String: Any]
        let agents = try XCTUnwrap(raw?["agents"] as? [String: [String: Any]])
        let known: Set<String> = [
            "state_events", "failure_signal", "interrupt_signal", "idle_signal", "permission_wait", "midturn_input",
            "phone_input", "elicitation", "registry_probe", "compressed_transcript", "subagent_feed", "analytics",
            "launch_hooks", "background_tasks", "app_session_id", "analytics_context"
        ]
        for (kind, row) in agents {
            XCTAssertEqual(Set(row.keys), known, kind)
        }
    }
}

import XCTest
import WatchtowerCore

/// The Desktop reads the sidecar `ai session` writes (#737): Go's pinned
/// fixture `internal/chat/testdata/claude_ai_connectors.json` decodes here.
@MainActor
final class ClaudeAIConnectorsFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/chat/testdata/claude_ai_connectors.json")
    }

    func testConnectorsFileDecodesGoFixture() throws {
        let file = try XCTUnwrap(ClaudeAIConnectorsFile.read(at: Self.fixtureURL.path))
        XCTAssertEqual(file.updatedAt, ISO8601DateFormatter().date(from: "2026-10-17T09:30:00Z"))
        XCTAssertTrue(file.available)
        XCTAssertEqual(file.unavailableReason, "")
        XCTAssertEqual(file.servers.map(\.name), ["Claude Docs", "Connector A", "Connector B", "Connector C", "Connector D"])
        XCTAssertEqual(file.servers.map(\.status), [.connected, .needsAuth, .disabled, .pending, .failed])
        XCTAssertEqual(file.servers[0].tools, [
            .init(name: "read", readOnly: true),
            .init(name: "update"),
            .init(name: "delete", destructive: true)
        ])
        XCTAssertEqual(file.servers[1].tools, [])
        XCTAssertEqual(file.servers[2].tools, [
            .init(name: "search", readOnly: true),
            .init(name: "send")
        ], "an explicit false reads as no hint")
    }

    func testConnectorsFileMissingIsEmpty() throws {
        XCTAssertNil(try ClaudeAIConnectorsFile.read(at: dir.appendingPathComponent("absent.json").path))
        let model = ClaudeAIConnectorsModelTests.makeModel(filePath: dir.appendingPathComponent("absent.json").path,
                                                           configPath: dir.appendingPathComponent("config.yaml").path)
        model.reload()
        XCTAssertNil(model.file)
        XCTAssertEqual(model.servers, [])
        XCTAssertNil(model.readError, "no file yet is not an error")
        XCTAssertEqual(model.switches, ClaudeAIConnectorSwitches(connectors: true, disabled: []),
                       "everything is on by default (ask #236)")
    }

    /// Present but undecodable is a third state, never "no file".
    func testUndecodableFileThrowsAndTheModelReportsIt() throws {
        let path = dir.appendingPathComponent(ClaudeAIConnectorsFile.fileName).path
        try Data("{\"servers\": [".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try ClaudeAIConnectorsFile.read(at: path))
        let model = ClaudeAIConnectorsModelTests.makeModel(filePath: path,
                                                           configPath: dir.appendingPathComponent("config.yaml").path)
        model.reload()
        XCTAssertNotNil(model.readError)
        XCTAssertNil(model.file)
    }

    /// Unknown keys are ignored, an unknown status reads as failed (as Go
    /// writes it), a null list is empty and an unavailable reason comes through.
    func testUnknownStatusNullListsAndUnavailable() throws {
        let path = dir.appendingPathComponent(ClaudeAIConnectorsFile.fileName).path
        try Data("""
        {"updated_at":"2026-10-17T09:30:00Z","available":false,"unavailable_reason":"signed in with an API key",
         "future":1,"servers":[{"name":"X","status":"weird","tools":null,"extra":true}]}
        """.utf8).write(to: URL(fileURLWithPath: path))
        let file = try XCTUnwrap(ClaudeAIConnectorsFile.read(at: path))
        XCTAssertFalse(file.available)
        XCTAssertEqual(file.unavailableReason, "signed in with an API key")
        XCTAssertEqual(file.servers, [.init(name: "X", status: .failed, tools: [])])

        try Data(#"{"updated_at":"2026-10-17T09:30:00Z","available":true,"servers":null}"#.utf8)
            .write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(try ClaudeAIConnectorsFile.read(at: path)?.servers, [])
    }

    func testSwitchesReadListCSVAndDefaults() throws {
        let path = dir.appendingPathComponent("config.yaml").path
        try "ai:\n  provider: claude\n".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ClaudeAIConnectorSwitches.read(configPath: path), ClaudeAIConnectorSwitches())

        try "ai:\n  claude_ai:\n    connectors: false\n    disabled_connectors:\n      - Connector B\n      - Connector A\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ClaudeAIConnectorSwitches.read(configPath: path),
                       ClaudeAIConnectorSwitches(connectors: false, disabled: ["Connector B", "Connector A"]))

        try "ai:\n  claude_ai:\n    disabled_connectors: \" Connector A, ,Connector B,Connector A\"\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ClaudeAIConnectorSwitches.read(configPath: path),
                       ClaudeAIConnectorSwitches(connectors: true, disabled: ["Connector A", "Connector B"]))

        try "ai:\n  claude_ai:\n    connectors: maybe\n".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ClaudeAIConnectorSwitches.read(configPath: path))
    }

    /// Absent keys are the defaults; a key present with a type Go can't load
    /// is an error naming it, never "everything on".
    func testSwitchesOfTheWrongTypeAreAnError() throws {
        let path = dir.appendingPathComponent("config.yaml").path
        for yaml in ["ai: claude\n", "ai:\n  claude_ai: false\n", "ai:\n  claude_ai:\n    disabled_connectors: 42\n",
                     "ai:\n  claude_ai:\n    disabled_connectors:\n      - {a: 1}\n", "- a\n", "ai: [\n"] {
            try yaml.write(toFile: path, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try ClaudeAIConnectorSwitches.read(configPath: path), yaml) { error in
                XCTAssertFalse((error as? ClaudeAIConnectorsReadError)?.message.isEmpty ?? true, yaml)
            }
        }
        for yaml in ["", "# nothing\n", "ai:\n", "ai:\n  claude_ai:\n"] {
            try yaml.write(toFile: path, atomically: true, encoding: .utf8)
            XCTAssertEqual(try ClaudeAIConnectorSwitches.read(configPath: path), ClaudeAIConnectorSwitches(), yaml)
        }
    }

    /// Go's `TestServerToken_Mapping` cases (with the prefix Go adds) and
    /// `DisabledConnectorTokens`: every spelling Go switches off reads off here.
    func testServerTokenMatchesGo() {
        let cases = [
            "Claude Docs": "claude_ai_Claude_Docs",
            "claude.ai Google Calendar": "claude_ai_Google_Calendar",
            "Atlassian-Rovo": "claude_ai_Atlassian-Rovo",
            "Café/Notes v2.1": "claude_ai_Caf_Notes_v2_1",
            "Notes 📝": "claude_ai_Notes",
            " Connector A ": "claude_ai_Connector_A",
            "Example Tool (2)": "claude_ai_Example_Tool_2"
        ]
        for (name, token) in cases {
            XCTAssertEqual(ClaudeAIConnectorSwitches.serverToken(name), token, name)
        }
        let switches = ClaudeAIConnectorSwitches(disabled: ["claude.ai Gmail", "Connector_A"])
        XCTAssertTrue(switches.isDisabled("Gmail"))
        XCTAssertTrue(switches.isDisabled("Connector A"))
        XCTAssertFalse(switches.isDisabled("Connector B"))
        XCTAssertEqual(switches.disabling("Gmail", false), ["Connector_A"], "on drops every spelling")
        XCTAssertEqual(switches.disabling("Connector A", true), ["Connector_A", "claude.ai Gmail"],
                       "already off: no second spelling")
        XCTAssertEqual(switches.disabling("Zeta", true), ["Connector_A", "Zeta", "claude.ai Gmail"])
    }

    func testStatusAndToolsText() {
        XCTAssertEqual(ClaudeAIConnectorsModel.statusText(.connected, switchedOn: true), "Connected")
        XCTAssertEqual(ClaudeAIConnectorsModel.statusText(.connected, switchedOn: false), "Off")
        XCTAssertEqual(ClaudeAIConnectorsModel.statusText(.disabled, switchedOn: true), "On from the next chat turn")
        XCTAssertEqual(ClaudeAIConnectorsModel.statusText(.needsAuth, switchedOn: true), "Not connected")
        XCTAssertEqual(ClaudeAIConnectorsModel.toolsText([
            .init(name: "search", readOnly: true),
            .init(name: "send"),
            .init(name: "delete", destructive: true)
        ]), "search (read-only) · send · delete (destructive)")
        XCTAssertEqual(ClaudeAIConnectorsModel.toolsText([]), "")
    }
}

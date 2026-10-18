import XCTest
import WatchtowerCore

/// Settings → claude.ai tools switches (#737): written through
/// `watchtower config set`, then the main chat's idle sessions retire.
@MainActor
final class ClaudeAIConnectorsModelTests: XCTestCase {
    /// Stands in for the CLI: records each call and, unless told to fail,
    /// applies `config set` to the config file as Go would.
    private final class ConfigSetRunner: CLIRunnerProtocol, @unchecked Sendable {
        let configPath: String
        var calls: [[String]] = []
        var failure: Error?

        init(configPath: String) { self.configPath = configPath }

        func run(args: [String]) async throws -> Data {
            calls.append(args)
            if let failure { throw failure }
            var switches = try ClaudeAIConnectorSwitches.read(configPath: configPath)
            switch args[2] {
            case "ai.claude_ai.connectors": switches.connectors = args[3] == "true"
            default: switches.disabled = args[3].split(separator: ",").map(String.init)
            }
            let list = switches.disabled.map { "      - \($0)\n" }.joined()
            try "ai:\n  claude_ai:\n    connectors: \(switches.connectors)\n    disabled_connectors:\n\(list)"
                .write(toFile: configPath, atomically: true, encoding: .utf8)
            return Data()
        }
    }

    private var dir: URL!
    private var configPath: String { dir.appendingPathComponent("config.yaml").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    static func makeModel(
        filePath: String?,
        configPath: String,
        runner: CLIRunnerProtocol? = nil
    ) -> ClaudeAIConnectorsModel {
        ClaudeAIConnectorsModel(filePath: { filePath }, configPath: configPath, cliRunner: runner)
    }

    func testToggleWritesSortedCSVAndRetires() async throws {
        // "Zeta" is switched off but no longer listed: it stays off.
        try "ai:\n  claude_ai:\n    disabled_connectors:\n      - Zeta\n"
            .write(toFile: configPath, atomically: true, encoding: .utf8)
        let runner = ConfigSetRunner(configPath: configPath)
        let model = Self.makeModel(filePath: nil, configPath: configPath, runner: runner)
        var retired = 0
        model.onSwitched = { retired += 1 }
        model.reload()
        XCTAssertFalse(model.isEnabled("Zeta"))
        XCTAssertTrue(model.isEnabled("Connector B"))

        await model.setEnabled(name: "Connector B", false)
        await model.setEnabled(name: "Connector A", false)
        XCTAssertEqual(runner.calls, [
            ["config", "set", "ai.claude_ai.disabled_connectors", "Connector B,Zeta"],
            ["config", "set", "ai.claude_ai.disabled_connectors", "Connector A,Connector B,Zeta"]
        ])
        XCTAssertFalse(model.isEnabled("Connector B"))
        XCTAssertEqual(retired, 2)

        await model.setEnabled(name: "Connector B", true)
        XCTAssertEqual(runner.calls.last, ["config", "set", "ai.claude_ai.disabled_connectors", "Connector A,Zeta"])
        XCTAssertTrue(model.isEnabled("Connector B"))

        await model.setAllEnabled(false)
        XCTAssertEqual(runner.calls.last, ["config", "set", "ai.claude_ai.connectors", "false"])
        XCTAssertFalse(model.switches.connectors)
        XCTAssertEqual(retired, 4)
        XCTAssertNil(model.writeError)

        // Everything back on: an empty list is written as "" (none disabled).
        await model.setEnabled(name: "Connector A", true)
        await model.setEnabled(name: "Zeta", true)
        XCTAssertEqual(runner.calls.last, ["config", "set", "ai.claude_ai.disabled_connectors", ""])
    }

    /// Two switches flipped at once: the second write starts from the first's
    /// result, so neither is lost.
    func testConcurrentTogglesAreSerialized() async throws {
        let runner = ConfigSetRunner(configPath: configPath)
        let model = Self.makeModel(filePath: nil, configPath: configPath, runner: runner)
        async let first: Void = model.setEnabled(name: "Connector A", false)
        async let second: Void = model.setEnabled(name: "Connector B", false)
        _ = await (first, second)
        XCTAssertEqual(Set(model.switches.disabled), ["Connector A", "Connector B"])
        XCTAssertEqual(runner.calls.count, 2)
    }

    func testFailedWriteKeepsStateAndReports() async throws {
        let runner = ConfigSetRunner(configPath: configPath)
        runner.failure = CLIRunnerError.nonZeroExit(code: 1, stderr: "config is locked")
        let model = Self.makeModel(filePath: nil, configPath: configPath, runner: runner)
        var retired = 0
        model.onSwitched = { retired += 1 }
        model.reload()

        await model.setEnabled(name: "Connector A", false)
        XCTAssertTrue(model.isEnabled("Connector A"), "a failed write keeps the old state")
        XCTAssertTrue(try XCTUnwrap(model.writeError).contains("config is locked"))

        await model.setAllEnabled(false)
        XCTAssertTrue(model.switches.connectors)
        XCTAssertEqual(retired, 0, "nothing changed, so no session retires")
        XCTAssertFalse(model.isWriting)

        // Settings closed and opened again: the refusal is still shown.
        model.reload()
        XCTAssertNotNil(model.writeError)

        runner.failure = nil
        await model.setAllEnabled(false)
        XCTAssertNil(model.writeError, "a later success clears the error")
        XCTAssertEqual(retired, 1)
    }

    /// A list that can't be read stays reported when a switch is saved: the
    /// section never falls back to "no connectors listed yet".
    func testSavedSwitchKeepsAReadError() async throws {
        let path = dir.appendingPathComponent(ClaudeAIConnectorsFile.fileName).path
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        let model = Self.makeModel(filePath: path, configPath: configPath, runner: ConfigSetRunner(configPath: configPath))
        model.reload()
        XCTAssertNotNil(model.readError)
        await model.setAllEnabled(false)
        XCTAssertNil(model.writeError)
        XCTAssertNotNil(model.readError)
    }

    /// `config set` splits on commas: such a name is refused, visibly, and nothing runs.
    func testNameWithACommaIsRefused() async {
        let runner = ConfigSetRunner(configPath: configPath)
        let model = Self.makeModel(filePath: nil, configPath: configPath, runner: runner)
        await model.setEnabled(name: "Mail, Calendar", false)
        XCTAssertEqual(runner.calls, [])
        XCTAssertNotNil(model.writeError)
    }
}

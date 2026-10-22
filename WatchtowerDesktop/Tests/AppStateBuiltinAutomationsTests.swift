import XCTest
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// The built-in card's app-side writes (C2 Task 10): Turn On/Off through the
/// feature manager, the When save through the config, and the empty states'
/// "Change the hour" opening Morning brief's card.
@MainActor
final class AppStateBuiltinAutomationsTests: XCTestCase {
    /// A features CLI whose list follows its own enable/disable calls.
    private final class FeaturesRunner: CLIRunnerProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var states: [String: String]
        private(set) var calls: [[String]] = []
        var failSwitch: Error?

        init(_ states: [String: String]) {
            self.states = states
        }

        func run(args: [String]) async throws -> Data {
            try lock.withLock {
                calls.append(args)
                if args.count == 3, args[0] == "features", ["enable", "disable"].contains(args[1]) {
                    if let failSwitch { throw failSwitch }
                    states[args[2]] = args[1] == "enable" ? "enabled" : "disabled"
                }
                let rows = states.keys.sorted().map { id in
                    """
                    {"id":"\(id)","title":"\(id)","description":"d","tagline":"t","benefits":[],"icon":"i",\
                    "state":"\(states[id] ?? "disabled")","core":false,"parent":"","config_key":"\(id).enabled",\
                    "cost":"light","feeds_into":[],"sub_toggles":[]}
                    """
                }
                return Data("{\"features\":[\(rows.joined(separator: ","))]}".utf8)
            }
        }
    }

    private func make(_ runner: FeaturesRunner) -> (AppState, FakeDaemon) {
        let appState = AppState.isolated(featuresRunner: runner)
        let daemon = FakeDaemon()
        appState.daemonControlOverride = daemon
        return (appState, daemon)
    }

    // MARK: - Turn On / Turn Off

    func testSetBuiltinEnabledSwitchesTheNamedFeaturesAndRestartsOnce() async {
        let runner = FeaturesRunner(["briefing": "enabled", "day-plan": "enabled", "ideas": "enabled"])
        let (appState, daemon) = make(runner)

        let off = await appState.setBuiltinEnabled(["briefing", "day-plan"], on: false)

        XCTAssertNil(off)
        XCTAssertEqual(runner.calls.filter { $0[1] != "list" }, [
            ["features", "disable", "briefing"], ["features", "disable", "day-plan"]
        ])
        XCTAssertEqual(daemon.restarts, 1)

        let on = await appState.setBuiltinEnabled(["briefing", "day-plan"], on: true)
        XCTAssertNil(on)
        XCTAssertEqual(runner.calls.filter { $0[1] != "list" }.suffix(2), [
            ["features", "enable", "briefing"], ["features", "enable", "day-plan"]
        ])
        XCTAssertEqual(daemon.restarts, 2)
    }

    func testSetBuiltinEnabledSaysBusyAndPassesTheFailureOn() async {
        let runner = FeaturesRunner(["briefing": "enabled"])
        let (appState, daemon) = make(runner)
        appState.featureManager.isApplying = true
        let busy = await appState.setBuiltinEnabled(["briefing"], on: false)
        XCTAssertEqual(busy, AppState.featureChangesBusy)
        appState.featureManager.isApplying = false

        runner.failSwitch = CLIRunnerError.nonZeroExit(code: 1, stderr: "config locked")
        let failed = await appState.setBuiltinEnabled(["briefing"], on: false)
        XCTAssertEqual(failed?.contains("config locked"), true)
        XCTAssertEqual(daemon.restarts, 0)
    }

    // MARK: - When save

    private func tempConfig(_ yaml: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("builtin-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("config.yaml").path
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testSaveBuiltinParametersWritesThenRestarts() async throws {
        let path = try tempConfig("briefing:\n  hour: 8\n")
        let (appState, daemon) = make(FeaturesRunner([:]))

        let result = await appState.saveBuiltinParameters(["briefing.hour": "9"]) { ConfigService(configPath: path) }

        XCTAssertNil(result)
        XCTAssertEqual(ConfigService(configPath: path).briefingHour, 9)
        XCTAssertEqual(daemon.restarts, 1)
    }

    func testSaveBuiltinParametersRefusalAndRestartFailure() async throws {
        let path = try tempConfig("briefing:\n  hour: 8\n")
        let (appState, daemon) = make(FeaturesRunner([:]))

        let refused = await appState.saveBuiltinParameters(["ideas.enabled": "true"]) { ConfigService(configPath: path) }
        XCTAssertEqual(refused, "This setting can't be saved here: ideas.enabled")
        XCTAssertEqual(daemon.restarts, 0, "nothing written, nothing to restart for")

        daemon.restartError = DaemonRestartError.startFailed(status: 1, stderr: "boom")
        let saved = await appState.saveBuiltinParameters(["briefing.hour": "10"]) { ConfigService(configPath: path) }
        XCTAssertEqual(saved?.hasPrefix("Saved. Watchtower could not restart to use it:"), true)
        XCTAssertEqual(ConfigService(configPath: path).briefingHour, 10)
    }

    // MARK: - "Change the hour"

    func testChangeTheHourOpensAutomations() {
        let (appState, _) = make(FeaturesRunner([:]))
        appState.performEmptyStateAction(.openBuiltin(id: "morning-brief", label: "Change the hour"))
        XCTAssertEqual(appState.selectedDestination, .automations)
    }
}

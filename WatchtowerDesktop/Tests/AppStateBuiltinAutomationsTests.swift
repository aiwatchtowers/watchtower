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
        /// A switch of one of these ids fails; the others go through.
        var failIDs: [String: Error] = [:]
        /// Runs once, during the first list read after a switch went
        /// through (the feature manager's trailing reload).
        var duringReloadAfterSwitch: (@MainActor () async -> Void)?
        private var switched = false

        init(_ states: [String: String]) {
            self.states = states
        }

        func run(args: [String]) async throws -> Data {
            let hook: (@MainActor () async -> Void)? = lock.withLock {
                guard switched, args.count > 1, args[1] == "list", let hook = duringReloadAfterSwitch else {
                    return nil
                }
                duringReloadAfterSwitch = nil
                return hook
            }
            if let hook { await hook() }
            return try lock.withLock {
                calls.append(args)
                if args.count == 3, args[0] == "features", ["enable", "disable"].contains(args[1]) {
                    if let failSwitch { throw failSwitch }
                    if let failure = failIDs[args[2]] { throw failure }
                    states[args[2]] = args[1] == "enable" ? "enabled" : "disabled"
                    switched = true
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

    /// Turn On with every feature on already: the daemon stopped the built-in
    /// (AUTO-08), so `features enable` of its first feature turns it on again
    /// (the CLI clears the stop) — once, with no daemon restart.
    func testSetBuiltinEnabledWithFeaturesOnTurnsAStoppedBuiltinOnAgain() async {
        let runner = FeaturesRunner(["briefing": "enabled", "day-plan": "enabled"])
        let (appState, daemon) = make(runner)

        let on = await appState.setBuiltinEnabled(["briefing", "day-plan"], on: true)

        XCTAssertNil(on)
        XCTAssertEqual(runner.calls.filter { $0[1] != "list" }, [["features", "enable", "briefing"]])
        XCTAssertEqual(daemon.restarts, 0)
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

    // MARK: - Turn On whose daemon restart fails (ask #503)

    private struct RestartBoom: LocalizedError {
        var errorDescription: String? { "the daemon did not stop in time" }
    }

    /// The feature is enabled, the restart throws: the returned reason is
    /// the call's own, and the app-wide banner carries the restart's error
    /// until a later restart succeeds.
    func testEnableWithFailedRestartSetsDaemonBanner() async throws {
        let runner = FeaturesRunner(["approval-cards": "disabled"])
        let (appState, daemon) = make(runner)
        daemon.running = true
        daemon.restartError = RestartBoom()

        let reason = await appState.setBuiltinEnabled(["approval-cards"], on: true)

        XCTAssertEqual(reason, RestartBoom().localizedDescription)
        XCTAssertEqual(appState.daemonStartFailure, AppState.daemonRestartFailureText(RestartBoom()))
        XCTAssertEqual(runner.calls.filter { $0[1] != "list" }, [["features", "enable", "approval-cards"]])
        XCTAssertEqual(daemon.restarts, 1)

        daemon.restartError = nil
        try await appState.restartOnChain(daemon)
        XCTAssertNil(appState.daemonStartFailure, "a later successful restart clears the banner")
    }

    /// The restart fails, then a newer restart succeeds while the feature
    /// manager still reloads: the stale failure never comes back over the
    /// cleared banner.
    func testStaleRestartFailureNeverOverwritesANewerSuccess() async throws {
        let runner = FeaturesRunner(["approval-cards": "disabled"])
        let (appState, daemon) = make(runner)
        daemon.running = true
        daemon.restartError = RestartBoom()
        runner.duringReloadAfterSwitch = {
            XCTAssertEqual(appState.daemonStartFailure, AppState.daemonRestartFailureText(RestartBoom()),
                           "the banner is up as soon as the restart failed")
            daemon.restartError = nil
            try? await appState.restartOnChain(daemon)
        }

        let reason = await appState.setBuiltinEnabled(["approval-cards"], on: true)

        XCTAssertEqual(reason, RestartBoom().localizedDescription, "the call's own reason stays")
        XCTAssertEqual(daemon.restarts, 2)
        XCTAssertNil(appState.daemonStartFailure, "the newer success keeps the banner clear")
    }

    /// Two features: the first enables, the second's `features enable`
    /// fails, the restart throws. The reason is the enable failure, the
    /// banner the restart's error; neither borrows the other's text.
    func testEnableFailureAndRestartFailureKeepTheirOwnTexts() async throws {
        let runner = FeaturesRunner(["briefing": "disabled", "day-plan": "disabled"])
        runner.failIDs["day-plan"] = CLIRunnerError.nonZeroExit(code: 1, stderr: "config locked")
        let (appState, daemon) = make(runner)
        daemon.running = true
        daemon.restartError = RestartBoom()

        let reason = await appState.setBuiltinEnabled(["briefing", "day-plan"], on: true)

        let enableFailure = CLIRunnerError.nonZeroExit(code: 1, stderr: "config locked").localizedDescription
        XCTAssertEqual(reason, enableFailure)
        XCTAssertEqual(appState.daemonStartFailure, AppState.daemonRestartFailureText(RestartBoom()))
        XCTAssertFalse(appState.daemonStartFailure?.contains("config locked") ?? true)
        XCTAssertFalse(reason?.contains(RestartBoom().localizedDescription) ?? true)
    }

    /// Needs approval's ⋯ Turn Off through the app's own hook (B Task 14):
    /// the feature write landed, so the menu shows no failure.
    func testNeedsApprovalMenuTurnOffThroughTheAppIsNoFailure() async throws {
        let runner = FeaturesRunner(["approval-cards": "enabled"])
        let (appState, daemon) = make(runner)
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        appState.initActionStrip(dbPool: pool)
        let menu = try XCTUnwrap(appState.inboxArtifactMenu)

        await menu.performApprovals(.turnOff)

        XCTAssertNil(menu.approvalsError)
        XCTAssertEqual(runner.calls.filter { $0[1] != "list" }, [["features", "disable", "approval-cards"]])
        XCTAssertEqual(daemon.restarts, 1)
    }

    /// Needs approval's note Turn On is the built-in card's own: exactly
    /// `features enable approval-cards`, once, then one restart (off); with
    /// the feature on, the stopped built-in's resume and no restart.
    func testNeedsApprovalTurnOnNamesOnlyItsFeature() async {
        let off = FeaturesRunner(["approval-cards": "disabled", "briefing": "disabled"])
        let (offState, offDaemon) = make(off)
        let offReason = await offState.turnOnNeedsApproval()
        XCTAssertNil(offReason)
        XCTAssertEqual(off.calls.filter { $0[1] != "list" }, [["features", "enable", "approval-cards"]])
        XCTAssertEqual(offDaemon.restarts, 1)

        let stopped = FeaturesRunner(["approval-cards": "enabled"])
        let (stoppedState, stoppedDaemon) = make(stopped)
        let stoppedReason = await stoppedState.turnOnNeedsApproval()
        XCTAssertNil(stoppedReason)
        XCTAssertEqual(stopped.calls.filter { $0[1] != "list" }, [["features", "enable", "approval-cards"]])
        XCTAssertEqual(stoppedDaemon.restarts, 0)
    }

    /// Resuming a stopped built-in (its feature on) restarts nothing, so it
    /// never sets the banner.
    func testResumeStoppedSetsNoDaemonBanner() async {
        let runner = FeaturesRunner(["approval-cards": "enabled"])
        let (appState, daemon) = make(runner)
        daemon.restartError = RestartBoom()

        let reason = await appState.setBuiltinEnabled(["approval-cards"], on: true)

        XCTAssertNil(reason)
        XCTAssertEqual(daemon.restarts, 0)
        XCTAssertNil(appState.daemonStartFailure)
    }

    /// The Automations tab's built-in card Turn On goes through the same
    /// call, so a failed restart shows the app-wide banner there too.
    func testBuiltinCardTurnOnFailedRestartShowsBannerInAutomationsTab() async throws {
        let runner = FeaturesRunner(["approval-cards": "disabled"])
        let (appState, daemon) = make(runner)
        daemon.running = true
        daemon.restartError = RestartBoom()
        appState.selectedDestination = .automations
        let card = try needsApprovalCard()

        await card.setEnabled(true, appState.setBuiltinEnabled)

        XCTAssertEqual(appState.selectedDestination, .automations)
        XCTAssertEqual(appState.daemonBanner, .failed(AppState.daemonRestartFailureText(RestartBoom())))
        XCTAssertEqual(card.actionError, RestartBoom().localizedDescription, "the card keeps its own line too")
    }

    /// The banner's **Retry** restarts the running daemon on the start
    /// queue; a success clears the line.
    func testBannerRetryRestartsAndClears() async {
        let runner = FeaturesRunner(["approval-cards": "disabled"])
        let (appState, daemon) = make(runner)
        daemon.running = true
        daemon.restartError = RestartBoom()
        _ = await appState.setBuiltinEnabled(["approval-cards"], on: true)
        XCTAssertNotNil(appState.daemonStartFailure)

        daemon.restartError = nil
        appState.startDaemonFromBanner()
        await appState.daemonStartChain?.value

        XCTAssertEqual(daemon.restarts, 2)
        XCTAssertNil(appState.daemonStartFailure)
    }

    /// Needs approval's built-in card over `show --json` (the Go golden).
    private func needsApprovalCard() throws -> BuiltinAutomationCardModel {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/automations/builtin/testdata/show_needs_approval.json")
        let block = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let detail: [String: Any] = [
            "id": 7, "slug": "needs-approval", "scope": "personal", "path": "builtin:needs-approval",
            "name": "Needs approval", "enabled": false, "runnable": true, "needs_confirmation": false,
            "recipe_text": "---\nname: Needs approval\n---\n", "builtin": block
        ]
        let show = try JSONSerialization.data(withJSONObject: detail)
        let automation = Automation(
            id: 7, slug: "needs-approval", path: "builtin:needs-approval", name: "Needs approval",
            triggerKind: "event", triggerSpecJSON: #"{"event":"approval"}"#, recipeText: "",
            approvalHash: "h", confirmedHash: "h", enabled: false, origin: .builtin, builtinID: "needs-approval")
        return BuiltinAutomationCardModel(automation: automation, cli: AutomationsCLI(runner: FakeCLIRunner(stdout: show)))
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

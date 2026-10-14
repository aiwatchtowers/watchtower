import XCTest
import SwiftUI
import ViewInspector
import WatchtowerCore
@testable import WatchtowerDesktop

@MainActor
final class FeatureEmptyStateViewTests: XCTestCase {
    private static let memoryCopy = EmptyStateCopy(
        icon: "archivebox", title: "Nothing remembered yet",
        landsHere: "What the assistant remembers about your work.",
        feature: .memory, primaryAction: .turnOn(featureID: "memory"))

    private func makeView(
        copy: EmptyStateCopy = memoryCopy,
        readiness: Readiness?,
        syncLine: String? = nil,
        turnOnError: String? = nil,
        onAction: @escaping (EmptyStateAction) -> Void = { _ in }
    ) -> FeatureEmptyState<EmptyView> {
        FeatureEmptyState(
            copy: copy, readiness: readiness, syncLine: syncLine,
            turnOnError: turnOnError, isTurningOn: false, onAction: onAction)
    }

    // MARK: - View

    func testOffShowsTurnOnButton() throws {
        var tapped: EmptyStateAction?
        let view = makeView(readiness: .off) { tapped = $0 }
        XCTAssertNoThrow(try view.inspect().find(text: "Nothing remembered yet"))
        XCTAssertNoThrow(try view.inspect().find(text: "What the assistant remembers about your work."))
        try view.inspect().find(button: "Turn on").tap()
        XCTAssertEqual(tapped, .turnOn(featureID: "memory"))
    }

    func testPreparingShowsLiveSyncLine() throws {
        let view = makeView(readiness: .preparing(detail: nil), syncLine: "Messages · 3/10 channels")
        XCTAssertNoThrow(try view.inspect().find(text: "Preparing now"))
        XCTAssertNoThrow(try view.inspect().find(text: "Messages · 3/10 channels"))
    }

    func testReadyHidesReadinessLine() throws {
        let view = makeView(readiness: .ready)
        XCTAssertThrowsError(try view.inspect().find(text: "Ready — Open"))
        XCTAssertThrowsError(try view.inspect().find(button: "Turn on"))
    }

    func testTurnOnHiddenWhenFeatureOn() throws {
        let view = makeView(readiness: .scheduled(.nextCycle(minutes: 15)))
        XCTAssertThrowsError(try view.inspect().find(button: "Turn on"))
        XCTAssertNoThrow(try view.inspect().find(text: "Within ~15 min"))
    }

    func testNilReadinessIsNeutral() throws {
        let view = makeView(readiness: nil, turnOnError: "boom")
        XCTAssertThrowsError(try view.inspect().find(button: "Turn on"))
        XCTAssertThrowsError(try view.inspect().find(text: "boom"))
        let calendar = EmptyStateCopy(
            icon: "calendar", title: "No meetings yet", landsHere: "Today's meetings with prep.",
            feature: .calendar, primaryAction: .connect(.calendar))
        XCTAssertThrowsError(try makeView(copy: calendar, readiness: nil).inspect().find(button: "Connect a calendar"))
        XCTAssertNil(FeatureEmptyState<EmptyView>.readinessLine(nil))
        // A tab's own action isn't state-gated: it stays.
        let targets = EmptyStateCopy(
            icon: "scope", title: "No targets yet", landsHere: "Your tasks.",
            feature: nil, primaryAction: .tabAction(label: "New target"))
        XCTAssertNoThrow(try makeView(copy: targets, readiness: nil).inspect().find(button: "New target"))
    }

    func testNeedsSourceShowsConnect() throws {
        var tapped: EmptyStateAction?
        let view = makeView(readiness: .needsSource(.slack)) { tapped = $0 }
        XCTAssertNoThrow(try view.inspect().find(text: "Connect Slack to get this"))
        try view.inspect().find(button: "Connect Slack").tap()
        XCTAssertEqual(tapped, .connect(.slack))
        XCTAssertThrowsError(try view.inspect().find(button: "Turn on"))
    }

    func testTurnOnErrorShownWithTheButton() throws {
        let view = makeView(readiness: .off, turnOnError: AppState.featureChangesBusy)
        XCTAssertNoThrow(try view.inspect().find(text: AppState.featureChangesBusy))
    }

    func testExtraContentRendered() throws {
        let view = FeatureEmptyState(
            copy: Self.memoryCopy, readiness: .scheduled(.inAboutADay), syncLine: nil,
            turnOnError: nil, isTurningOn: false, onAction: { _ in },
            extra: { Text("cheat") })
        XCTAssertNoThrow(try view.inspect().find(text: "cheat"))
    }

    func testOpenSettingsFeaturesMapsToFeaturesTab() {
        XCTAssertEqual(SettingsTab(emptyStateTab: "features"), .features)
        XCTAssertNil(SettingsTab(emptyStateTab: "feature"))
        XCTAssertNil(SettingsTab(emptyStateTab: "briefing"))
        // Every Settings tab the copy table names exists.
        for destination in SidebarDestination.allCases {
            let copy = EmptyStateCopyTable.copy(for: destination.rawValue, briefingHour: 8, dayPlanHour: 8)
            guard case .openSettings(let tab) = copy?.primaryAction else { continue }
            XCTAssertNotNil(SettingsTab(emptyStateTab: tab), "\(destination.rawValue): \(tab)")
        }
    }

    // MARK: - Turn on (AppState)

    /// A features CLI whose list follows its own `features enable` calls.
    private final class LiveFeaturesRunner: CLIRunnerProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var states: [String: String]
        private(set) var calls: [[String]] = []

        init(disabled: [String]) {
            states = Dictionary(uniqueKeysWithValues: disabled.map { ($0, "disabled") })
        }

        func run(args: [String]) async throws -> Data {
            lock.withLock {
                calls.append(args)
                if args.count == 3, args[0] == "features", args[1] == "enable" { states[args[2]] = "enabled" }
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

    private func makeAppState(_ runner: LiveFeaturesRunner) -> (AppState, FakeDaemon) {
        let appState = AppState.isolated(featuresRunner: runner)
        let daemon = FakeDaemon()
        appState.daemonControlOverride = daemon
        return (appState, daemon)
    }

    func testTurnOnBusyShowsMessage() async {
        let runner = LiveFeaturesRunner(disabled: ["memory"])
        let (appState, daemon) = makeAppState(runner)
        appState.featureManager.isApplying = true

        await appState.turnOnFeatureFromEmptyState("memory")

        XCTAssertEqual(appState.emptyStateTurnOnError(for: "memory"), AppState.featureChangesBusy)
        XCTAssertFalse(appState.isTurningOnFromEmptyState)
        XCTAssertEqual(daemon.restarts, 0)
        XCTAssertFalse(runner.calls.contains(["features", "enable", "memory"]))
    }

    func testTurnOnRestartFailureShowsError() async {
        let runner = LiveFeaturesRunner(disabled: ["memory"])
        let (appState, daemon) = makeAppState(runner)
        let failure = DaemonRestartError.startFailed(status: 1, stderr: "boom")
        daemon.restartError = failure

        await appState.turnOnFeatureFromEmptyState("memory")

        XCTAssertEqual(appState.emptyStateTurnOnError(for: "memory"), failure.localizedDescription)
        XCTAssertFalse(appState.isTurningOnFromEmptyState)
        XCTAssertEqual(daemon.restarts, 1)

        // The retry finds memory on and only restarts.
        daemon.restartError = nil
        await appState.turnOnFeatureFromEmptyState("memory")
        XCTAssertNil(appState.emptyStateTurnOnError(for: "memory"))
        XCTAssertEqual(daemon.restarts, 2)
        XCTAssertEqual(runner.calls.filter { $0 == ["features", "enable", "memory"] }.count, 1)
    }

    func testTurnOnErrorShowsOnlyForItsFeature() async {
        let runner = LiveFeaturesRunner(disabled: ["memory", "ideas"])
        let (appState, daemon) = makeAppState(runner)
        daemon.restartError = DaemonRestartError.startFailed(status: 1, stderr: "boom")

        await appState.turnOnFeatureFromEmptyState("memory")

        XCTAssertNotNil(appState.emptyStateTurnOnError(for: "memory"))
        XCTAssertNil(appState.emptyStateTurnOnError(for: "ideas"), "another tab's Turn on shows no error")
        XCTAssertNil(appState.turningOnFeatureID)
    }

    func testTurnOnSuccessClearsError() async {
        let runner = LiveFeaturesRunner(disabled: ["memory"])
        let (appState, daemon) = makeAppState(runner)
        appState.featureManager.isApplying = true
        await appState.turnOnFeatureFromEmptyState("memory")
        XCTAssertNotNil(appState.emptyStateTurnOnError(for: "memory"))
        appState.featureManager.isApplying = false

        await appState.turnOnFeatureFromEmptyState("memory")

        XCTAssertNil(appState.emptyStateTurnOnError(for: "memory"))
        XCTAssertFalse(appState.isTurningOnFromEmptyState)
        XCTAssertEqual(daemon.restarts, 1, "exactly one daemon restart")
        XCTAssertTrue(runner.calls.contains(["features", "enable", "memory"]))
        XCTAssertTrue(appState.featureManager.pending.isEmpty, "never the staged Settings → Features path")
    }
}

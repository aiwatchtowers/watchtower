import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Home is where the app opens, where navigation falls back to and where a
/// first run of onboarding lands; a setup re-run keeps the owner's tab.
@MainActor
final class HomeLandingTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    /// Every goal set lands on Home — the goals no longer pick a tab.
    func testFinishLandsOnHomeForEveryGoalSet() async throws {
        let catchUpFeatures: Set<String> = ["secretary-inbox", "slack-digests", "stream-digests"]
        let cases: [(Set<OnboardingGoal>, Bool, Set<String>)] = [
            ([.workCommunication, .development], true, []),
            ([.workCommunication, .development], false, []),
            ([.workCommunication, .development], true, catchUpFeatures),
            ([.workCommunication], true, catchUpFeatures),
            ([.workCommunication], true, ["secretary-inbox"]),
            ([.development], true, []),
            ([.tasksAndJira], false, []),
            ([], false, [])
        ]
        for (goals, slack, disabled) in cases {
            let (manager, path) = try TestDatabase.createDatabaseManager()
            defer { TestDatabase.cleanup(path: path) }
            if slack {
                try await manager.dbPool.write { db in _ = try TestDatabase.insertSlackAccount(db, teamID: "T1") }
            }
            let open: @Sendable () throws -> DatabaseManager = { manager }
            let appState = AppState.isolated(openDatabase: open)
            appState.featureVisibility.disabledFeatureIDs = disabled
            appState.selectedDestination = .targets
            appState.needsOnboarding = true
            _ = await appState.openDatabaseForOnboarding()
            appState.onboarding.goTo(.connect)

            await appState.leaveOnboardingStep(.connect, route: OnboardingRoute(goals: goals)) {}

            XCTAssertEqual(appState.selectedDestination, .home, "\(goals) slack=\(slack) disabled=\(disabled)")
        }
    }

    /// A re-run that changed something (an account connected, so finish
    /// restarts the daemon) still goes back to the owner's tab.
    func testRerunKeepsTheCurrentTab() async throws {
        let manager = try XCTUnwrap(dbManager)
        let open: @Sendable () throws -> DatabaseManager = { manager }
        let appState = AppState.isolated(openDatabase: open)
        appState.databaseManager = manager
        appState.initSlackAccounts(dbPool: manager.dbPool)
        let vm = try XCTUnwrap(appState.slackAccountsViewModel)
        await vm.refreshAsync()
        let daemon = FakeDaemon()
        daemon.running = true
        appState.daemonControlOverride = daemon
        appState.selectedDestination = .targets
        appState.startOnboarding(enabledFeatureIDs: [], configuredLanguage: nil)
        try await manager.dbPool.write { db in _ = try TestDatabase.insertSlackAccount(db, teamID: "T1") }
        await vm.refreshAsync()

        await appState.leaveOnboardingStep(.purpose, route: OnboardingRoute(goals: [.development])) {}
        await appState.daemonStartChain?.value

        XCTAssertEqual(appState.onboarding.currentStep, .complete)
        XCTAssertEqual(daemon.restarts, 1, "the restart path, not the unchanged re-run")
        XCTAssertEqual(appState.selectedDestination, .targets)
    }

    func testLaunchDefaultIsHome() {
        XCTAssertEqual(AppState.isolated().selectedDestination, .home)
    }

    /// Every tab hidden under a dev-only install or with no source falls
    /// back to Home, never to Inbox or Workbench.
    func testFallbackIsHomeForAnyHiddenTab() {
        let devOnlyDisabled = OnboardingFeaturePlan.managedFeatureIDs
            .subtracting(OnboardingFeaturePlan.enabledFeatureIDs(for: [.development]))
        let installs: [(disabled: Set<String>, connected: ConnectedSources, why: String)] = [
            (devOnlyDisabled, .none, "dev-only"),
            ([], .none, "no source")
        ]
        var checked = 0
        for install in installs {
            for destination in SidebarDestination.allCases
            where !destination.isVisible(disabledFeatures: install.disabled, connected: install.connected) {
                XCTAssertEqual(
                    SidebarDestination.fallbackDestination(
                        current: destination, disabled: install.disabled, connected: install.connected
                    ),
                    .home, "\(destination) \(install.why)"
                )
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0, "the fixture hides some tab")
    }

    func testHomeIsAlwaysVisible() {
        let allFeatures = OnboardingFeaturePlan.managedFeatureIDs
            .union(SidebarDestination.allCases.flatMap { $0.requiredFeatures ?? [] })
        let disabledSets: [Set<String>] = [[], allFeatures, ["memory", "tracks"]]
        for disabled in disabledSets {
            for connected in [ConnectedSources.none, .all] {
                XCTAssertTrue(
                    SidebarDestination.home.isVisible(disabledFeatures: disabled, connected: connected),
                    "disabled=\(disabled) connected=\(connected)"
                )
            }
        }
    }

    func testHomeIsTheFirstRootItem() {
        XCTAssertEqual(SidebarDestination.rootItems.first, .home)
        XCTAssertEqual(SidebarDestination.home.icon, "house")
        XCTAssertEqual(SidebarDestination.home.rawValue, "home")
        XCTAssertEqual(SidebarDestination.home.title, "Home")
    }
}

import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Automations tab (spec §12.1, D12): always on, no feature id.
@MainActor
final class SidebarAutomationsVisibilityTests: XCTestCase {
    func testTabIdentity() {
        XCTAssertEqual(SidebarDestination.automations.title, "Automations")
        XCTAssertEqual(SidebarDestination.automations.icon, "gearshape.2")
        XCTAssertNil(SidebarDestination.automations.requiredFeatures)
        let root = SidebarDestination.rootItems
        let workbench = root.firstIndex(of: .workbench)
        XCTAssertEqual(root.firstIndex(of: .automations), workbench.map { $0 + 1 }, "right after Workbench")
    }

    func testAutomationsAlwaysVisible() {
        XCTAssertTrue(SidebarDestination.automations.isVisible(disabledFeatures: [], connected: .none),
                      "no source gate: recipes read whatever they declare")
        XCTAssertTrue(SidebarDestination.automations.isVisible(disabledFeatures: ["automations"], connected: .none),
                      "an old disabled id means nothing")
        XCTAssertNil(SidebarDestination.fallbackDestination(current: .automations, disabled: [], connected: .none))
    }

    func testBadgeColor() {
        XCTAssertEqual(SidebarView.badgeColor(for: .automations, overdue: false), .orange)
    }

    /// The badge's view model is built on the first-run path too, where the
    /// launch skipped the sidebar (review rule: every path that reveals the surface).
    func testViewModelConstructedOnCompleteOnboardingPath() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let suite = "SidebarAutomationsVisibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let features = FeatureManagerService(runner: FakeCLIRunner(stdout: Data(#"{"features":[]}"#.utf8)))
        let appState = AppState(onboardingDefaults: defaults, featureManager: features)
        appState.wireAppDatabaseOverride = { _ in }
        appState.databaseManager = manager
        XCTAssertNil(appState.automationsViewModel)

        appState.completeOnboarding()
        defer {
            appState.automationsViewModel?.stop()
            appState.stopSidebarCounts()
        }

        let vm = try XCTUnwrap(appState.automationsViewModel)
        appState.completeOnboarding()
        XCTAssertTrue(appState.automationsViewModel === vm, "built once, so in-flight state survives")
    }

    func testOpenAutomationRunNavigates() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let suite = "SidebarAutomationsVisibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let features = FeatureManagerService(runner: FakeCLIRunner(stdout: Data(#"{"features":[]}"#.utf8)))
        let appState = AppState(onboardingDefaults: defaults, featureManager: features)
        appState.wireAppDatabaseOverride = { _ in }
        appState.databaseManager = manager
        appState.completeOnboarding()
        defer {
            appState.automationsViewModel?.stop()
            appState.stopSidebarCounts()
        }

        appState.openAutomationRun(automationID: 4, runID: 9)

        XCTAssertEqual(appState.selectedDestination, .automations)
        XCTAssertEqual(appState.automationsViewModel?.selectedID, 4)
        XCTAssertEqual(appState.automationsViewModel?.expandedRuns, [9])
    }
}

import XCTest
import GRDB
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

    /// The "turned off" notice (#584) of a built-in the daemon stopped (AUTO-08)
    /// opens the automation's `.card`, which renders `BuiltinAutomationCard`
    /// for a built-in row: its **Turn On** goes through `setBuiltinEnabled` →
    /// `resumeStoppedBuiltin` (`features enable`), never `automations enable`
    /// (refused for a built-in; AppStateBuiltinAutomationsTests).
    func testDisabledNoticeOfABuiltinOpensItsBuiltinCard() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let id = try manager.dbPool.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO automations (slug, scope, path, name, trigger_kind, trigger_spec, origin, builtin_id,
                    enabled, disabled_reason)
                VALUES ('morning-brief', 'personal', 'builtin:morning-brief', 'Morning brief', 'sync',
                    '{"sync":"morning_brief"}', 'builtin', 'morning-brief', 0, 'runaway script — check and re-enable')
                """)
            // No disabled_at: the app's failure watch would post a real
            // notification from the test process; the click is driven below.
            return db.lastInsertedRowID
        }
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

        // What a click on the notice does (NotificationDelegate.routeAutomationRun
        // with the notice's AutomationRunNotifier.userInfo), without the window.
        let target = try XCTUnwrap(NotificationDelegate.automationRunTarget(
            AutomationRunNotifier.userInfo(automationID: id, runID: 7)))
        appState.openAutomationRun(automationID: target.automationID, runID: target.runID)

        XCTAssertEqual(appState.selectedDestination, .automations)
        let vm = try XCTUnwrap(appState.automationsViewModel)
        guard case let .card(shown) = vm.panel else { return XCTFail("panel = \(vm.panel), want the card") }
        XCTAssertEqual(shown, id)
    }

    /// New Automation… in a workbench's menu (spec 2026-10-20 §4, A2): the
    /// tab opens the New panel with that workbench's scope fixed.
    func testNewAutomationForWorkbenchNavigates() throws {
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

        let workbench = try manager.dbPool.write { db -> Workbench in
            let id = try TestDatabase.insertWorkbench(db, name: "acme", folder: "/tmp/acme")
            return try XCTUnwrap(Workbench.fetchOne(db, sql: "SELECT * FROM projects WHERE id = ?", arguments: [id]))
        }

        // The tab was last left on Reactions: the panel must still be seen.
        let key = AutomationsSection.storageKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(AutomationsSection.reactions.rawValue, forKey: key)

        appState.newAutomation(forWorkbench: workbench)

        XCTAssertEqual(appState.selectedDestination, .automations)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), AutomationsSection.automations.rawValue)
        XCTAssertEqual(appState.automationsViewModel?.panel, .new(AutomationNewFlow(
            fixedScope: .workbench(id: workbench.id, name: "acme", folder: "/tmp/acme"))))
    }

    /// Another surface (an Inbox card) opens the editor on a recipe text in
    /// a scope: a fresh new draft starting from that text.
    func testOpenAutomationDraftShowsTheEditor() throws {
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

        let key = AutomationsSection.storageKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(AutomationsSection.tracks.rawValue, forKey: key)

        appState.openAutomationDraft(text: "---\nname: Digest\n---\n", scope: .personal)

        XCTAssertEqual(appState.selectedDestination, .automations)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), AutomationsSection.automations.rawValue)
        guard case let .editor(.newDraft(contextID, scope, startText)) = appState.automationsViewModel?.panel else {
            return XCTFail("the editor opens on a new draft")
        }
        XCTAssertFalse(contextID.isEmpty)
        XCTAssertEqual(scope, .personal)
        XCTAssertEqual(startText, "---\nname: Digest\n---\n")
    }
}

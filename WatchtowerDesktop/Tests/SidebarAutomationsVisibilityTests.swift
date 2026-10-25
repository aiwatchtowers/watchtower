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

        appState.newAutomation(forWorkbench: workbench)

        XCTAssertEqual(appState.selectedDestination, .automations)
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

        appState.openAutomationDraft(text: "---\nname: Digest\n---\n", scope: .personal)

        XCTAssertEqual(appState.selectedDestination, .automations)
        guard case let .editor(.newDraft(contextID, scope, startText)) = appState.automationsViewModel?.panel else {
            return XCTFail("the editor opens on a new draft")
        }
        XCTAssertFalse(contextID.isEmpty)
        XCTAssertEqual(scope, .personal)
        XCTAssertEqual(startText, "---\nname: Digest\n---\n")
    }

    /// One list (Built in, Personal, workbenches): the segmented section
    /// picker and the Reactions / Tracks sections are gone (C3), and the
    /// Slack pointer and the cheat sheet select the Reactions built-in.
    func testAutomationsHasNoSectionPicker() throws {
        let automations = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views/Automations")
        let view = try String(contentsOf: automations.appendingPathComponent("AutomationsView.swift"), encoding: .utf8)
        for gone in ["KitSegmentedPicker", "automations.section", "ReactionsSectionView", "TracksSectionView",
                     "tracksVisible"] {
            XCTAssertFalse(view.contains(gone), "AutomationsView still has \(gone)")
        }
        for file in ["ReactionsSectionView.swift", "TracksSectionView.swift"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: automations.appendingPathComponent(file).path), file)
        }

        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let id = try manager.dbPool.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO automations (slug, scope, path, name, trigger_kind, trigger_spec, origin, builtin_id, enabled)
                VALUES ('reactions', 'personal', 'builtin:reactions', 'Reactions', 'sync', '{"sync":"reactions"}',
                    'builtin', 'reactions', 1)
                """)
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
        appState.automationsViewModel?.refresh()

        appState.openBuiltinAutomation(BuiltinAutomationCard.reactionsID)

        XCTAssertEqual(appState.selectedDestination, .automations)
        XCTAssertEqual(appState.automationsViewModel?.selectedID, id)
        XCTAssertEqual(appState.automationsViewModel?.panel, .card(id))
        XCTAssertEqual(ReactionCheatSheetView.editLabel, "Edit reaction commands in Automations…")
    }
}

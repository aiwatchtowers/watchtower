import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Inbox drawn from the wired views (plan Task 12): the folder menu, the
/// root's entries and the selected artifact through `ActionStripActionsView`
/// over a test database — Waiting for me pinned first, the legacy entries
/// (today's Morning brief, Track my threads, Idea finder) and an owner
/// automation's artifact. b-01's main panel. Sample data only, at one fixed
/// moment: Go's desktop case `desktop_shot_folders_root` and its feed.
@MainActor
enum InboxFoldersShotFixtures {
    private static var paths: [String] = []
    private static let defaultsSuite = "InboxFoldersShotFixtures"
    nonisolated static let now = AutomationDates.parse("2026-11-06T12:00:00Z") ?? Date()

    static func cleanUp() {
        paths.forEach(TestDatabase.cleanup(path:))
        paths = []
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
    }

    /// b-01's main panel: the root selected, Weekly mail roundup open.
    static func root() async -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            paths.append(path)
            // The tree, Waiting for me with four open pings, today's brief,
            // two tracks, one idea to judge, three approvals and the weekly
            // roundup (artifact 2).
            let tower = try InboxShotFeed.seeded("desktop_shot_folders_root", pool)
            let weekly: Int64 = 2
            let defaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
            defaults.removePersistentDomain(forName: defaultsSuite)
            let clock = now
            // Labeled: a trailing closure would bind to `automationsWake`.
            // swiftlint:disable:next trailing_closure
            let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner(), defaults: defaults, clock: { clock })
            await InboxShotFeed.listed(vm, tower) { await vm.selectEntry("artifact:\(weekly)") }
            return AnyView(ActionStripActionsView(
                vm: vm, cheatSheetRows: [], feature: .on(lastCheck: nil), isEnabling: false, featureError: nil,
                onEnable: {}, onOpenSettings: {}, onOpen: { _ in }, now: now
            )
            .environment(AppState())
            .detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }
}

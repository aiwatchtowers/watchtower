import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Briefings, Day Plan, Tracks and Ideas left the sidebar for the Inbox (C1
/// Task 11), and its filters for the root's legacy entries (inbox builder
/// B): every old way in — a `watchtower-nav://` link, the navigate helpers,
/// Home, a notification — lands on the Inbox's root with the legacy entry or
/// the day card open. The Inbox has no feature or source gate, so it is never
/// hidden.
@MainActor
final class InboxRouteTests: XCTestCase {
    private static let today = AppState.inboxToday()
    private var manager: DatabaseManager!
    private var path = ""
    private var savedFolder: Any?
    private var savedFilter: Any?

    override func setUp() async throws {
        (manager, path) = try TestDatabase.createDatabaseManager()
        // An owner, so the root lists today's day card (OWNER-02).
        try await manager.dbPool.write { db in
            _ = try TestDatabase.insertSlackAccount(db, currentUserID: "1:U1")
        }
        // `initActionStrip` keeps the remembered folder in the standard
        // defaults: each view model starts on the root, so a landing is the
        // route's own.
        savedFolder = UserDefaults.standard.object(forKey: ActionStripViewModel.folderKey)
        savedFilter = UserDefaults.standard.object(forKey: Self.oldFilterKey)
        UserDefaults.standard.removeObject(forKey: ActionStripViewModel.folderKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedFolder, forKey: ActionStripViewModel.folderKey)
        UserDefaults.standard.set(savedFilter, forKey: Self.oldFilterKey)
        TestDatabase.cleanup(path: path)
        manager = nil
    }

    /// The key the filter bar remembered its segment in, before the filters went.
    private static let oldFilterKey = "inbox.filter"

    /// An AppState on the test database with the Inbox's view model.
    private func appState(connected: ConnectedSources = .all) -> AppState {
        UserDefaults.standard.removeObject(forKey: ActionStripViewModel.folderKey)
        let state = AppState.isolated()
        state.databaseManager = manager
        state.featureVisibility.connectedSources = connected
        state.initActionStrip(dbPool: manager.dbPool)
        state.selectedDestination = .home
        return state
    }

    /// Where a route left the Inbox: its folder (nil = the root), the open
    /// legacy list, the selected entry and the open card.
    private struct Landing: Equatable {
        var folder: Int64?
        var list: InboxLegacyList?
        var entry: String?
        var selection: InboxSelection?

        static func legacy(_ list: InboxLegacyList, _ selection: InboxSelection? = nil) -> Self {
            Self(list: list, entry: InboxFolderEntry.legacy(list).id, selection: selection)
        }

        static func day(_ date: String) -> Self {
            Self(entry: "day:\(date)", selection: .day(date))
        }
    }

    private func landing(_ state: AppState) -> Landing? {
        guard let vm = state.actionStripViewModel else { return nil }
        let folder = vm.folderMenu.selectedFolderID
        return Landing(folder: folder == vm.folderMenu.tree.root.id ? nil : folder, list: vm.legacyList,
                       entry: vm.entrySelection, selection: vm.selection)
    }

    private func assertLanding(
        _ state: AppState,
        _ expected: Landing,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(state.selectedDestination, .inbox, message, file: file, line: line)
        XCTAssertEqual(landing(state), expected, message, file: file, line: line)
    }

    /// Waits (bounded) for a fire-and-forget route — a nav link, a Home
    /// click — to finish its Inbox read and selection.
    private func settle(_ state: AppState, _ expected: Landing) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if landing(state) == expected { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Old nav hosts

    func testOldNavHostsRouteToTheRootsEntries() async throws {
        let cases: [(String, InboxRoute, Landing)] = [
            ("briefings", .card(.day(Self.today)), .day(Self.today)),
            ("dayPlan", .card(.day(Self.today)), .day(Self.today)),
            ("day-plan", .card(.day(Self.today)), .day(Self.today)),
            ("tracks", .legacy(.tracks), .legacy(.tracks)),
            ("ideas", .legacy(.ideas), .legacy(.ideas))
        ]
        XCTAssertEqual(InboxRoute.aliasHosts, Set(cases.map(\.0)))
        for (host, route, expected) in cases {
            XCTAssertEqual(InboxRoute.fromNavHost(host, today: Self.today), route)
            let state = appState()
            state.isHelpChatShown = true
            XCTAssertTrue(state.visibleHelpScreenIDs.contains(host), host)
            state.openNavLink(NavLink.url(host))
            await settle(state, expected)
            assertLanding(state, expected, host)
            XCTAssertFalse(state.isHelpChatShown, "\(host): the popup closes")
        }
    }

    /// F16: a stored raw value of a removed destination (a `sidebar.hiddenItems`
    /// entry, an old chat answer's link) decodes to no destination and opens
    /// the Inbox's entry instead — it never crashes or lands on a ghost tab.
    func testPersistedOldDestinationDecodesToTheInbox() async throws {
        let expected: [String: InboxRoute] = [
            "briefings": .card(.day(Self.today)), "dayPlan": .card(.day(Self.today)),
            "ideas": .legacy(.ideas), "tracks": .legacy(.tracks)
        ]
        for (raw, route) in expected {
            XCTAssertNil(SidebarDestination(rawValue: raw), raw)
            XCTAssertEqual(InboxRoute.fromNavHost(raw, today: Self.today), route, raw)
            let state = appState()
            state.openNavLink(NavLink.url(raw))
            XCTAssertEqual(state.selectedDestination, .inbox, raw)
        }
        // A hidden-items entry naming one is ignored: FOCUS shows Catch Up and Inbox.
        XCTAssertEqual(SidebarSection.today.partition(hidden: Set(expected.keys)).visible, [.catchUp, .inbox])
    }

    /// With no source connected the Inbox still shows (no gate since C1),
    /// so the old screen names still open its entries.
    func testOldNavHostOpensTheInboxWithNoSource() {
        for host in InboxRoute.aliasHosts {
            let state = appState(connected: .none)
            XCTAssertTrue(state.visibleHelpScreenIDs.contains(host), host)
            state.openNavLink(NavLink.url(host))
            XCTAssertEqual(state.selectedDestination, .inbox, host)
        }
    }

    func testUnknownHostIsNotAnAlias() {
        XCTAssertNil(InboxRoute.fromNavHost("inbox", today: Self.today))
        XCTAssertNil(InboxRoute.fromNavHost("Tracks", today: Self.today))
        XCTAssertNil(InboxRoute.fromNavHost("settings", today: Self.today))
        let state = appState()
        state.openNavLink(NavLink.url("settings"))
        XCTAssertEqual(state.selectedDestination, .home)
    }

    /// An Inbox card's link to an old screen name is a screen link, opened through `openNavLink`.
    func testCardLinkToAnAliasIsAScreen() throws {
        let state = appState()
        let url = try XCTUnwrap(URL(string: "watchtower-nav://day-plan"))
        XCTAssertEqual(InboxCardLinkPolicy.route(url, navScreens: state.visibleHelpScreenIDs), .screen(url))
        XCTAssertEqual(InboxCardLinkPolicy.route(url, navScreens: appState(connected: .none).visibleHelpScreenIDs), .screen(url))
    }

    // MARK: - Navigate helpers

    func testNavigateHelpersOpenTheirCard() async throws {
        let briefingDate = "2026-10-20"
        let briefingID = try await manager.dbPool.write { db -> Int in
            // A day card exists for the date the day-plan route opens.
            try TestDatabase.insertDayPlan(db, planDate: "2026-10-19")
            try TestDatabase.insertBriefing(db, date: briefingDate)
            let id = Int(db.lastInsertedRowID)
            // The idea and track the helpers open: a route selects only a listed card.
            let idea = try TestDatabase.insertIdea(db, title: "A shared glossary")
            try db.execute(sql: "UPDATE ideas SET id = 5 WHERE id = ?", arguments: [idea])
            let track = try TestDatabase.insertTrack(db, text: "Launch")
            try db.execute(sql: "UPDATE tracks SET id = 7 WHERE id = ?", arguments: [track])
            return id
        }

        var state = appState()
        await state.navigateToIdea(5)?.value
        assertLanding(state, .legacy(.ideas, .idea(5)), "idea")

        state = appState()
        await state.navigateToTrack(7)?.value
        assertLanding(state, .legacy(.tracks, .track(7)), "track")

        state = appState()
        await state.navigateToDayPlan("2026-10-19")?.value
        assertLanding(state, .day("2026-10-19"), "day plan of a date")

        state = appState()
        await state.navigateToDayPlan()?.value
        assertLanding(state, .day(Self.today), "today's day plan")

        state = appState()
        await state.navigateToBriefing(briefingID)?.value
        assertLanding(state, .day(briefingDate), "a briefing opens its own day")

        state = appState()
        await state.navigateToBriefing(99_999)?.value
        assertLanding(state, .day(Self.today), "a vanished briefing opens today")
    }

    // MARK: - Home

    func testHomeBriefLinkOpensTheDayCard() async throws {
        let date = "2026-10-21"
        let briefingID = try await manager.dbPool.write { db -> Int in
            try TestDatabase.insertBriefing(db, date: date)
            return Int(db.lastInsertedRowID)
        }
        let state = appState()
        state.openHomeLink(.briefing(id: briefingID))
        await settle(state, .day(date))
        assertLanding(state, .day(date), "brief")

        let plan = appState()
        plan.openHomeLink(.feature(.dayPlan))
        await settle(plan, .day(Self.today))
        assertLanding(plan, .day(Self.today), "plan")
    }

    /// The brief and plan links show while their feature is on (the Inbox always shows).
    func testHomeBriefAndPlanLinksFollowTheInboxAndTheirFeature() {
        let state = appState()
        XCTAssertTrue(state.homeLinksAllowed.isSuperset(of: [.briefing, .dayPlan]))
        state.featureVisibility.disabledFeatureIDs = ["briefing"]
        XCTAssertFalse(state.homeLinksAllowed.contains(.briefing))
        XCTAssertTrue(state.homeLinksAllowed.contains(.dayPlan))
        let noSource = appState(connected: .none)
        XCTAssertTrue(noSource.homeLinksAllowed.isSuperset(of: [.briefing, .dayPlan]))
    }

    func testGettingReadyOpenForTheFourFeatures() async {
        let cases: [(ReadinessFeature, InboxRoute, Landing)] = [
            (.briefing, .card(.day(Self.today)), .day(Self.today)),
            (.dayPlan, .card(.day(Self.today)), .day(Self.today)),
            (.tracks, .legacy(.tracks), .legacy(.tracks)),
            (.ideas, .legacy(.ideas), .legacy(.ideas))
        ]
        for (feature, route, expected) in cases {
            XCTAssertEqual(InboxRoute.forFeature(feature, today: Self.today), route)
            XCTAssertNil(AppState.homeDestination(for: feature), "\(feature) has no tab of its own")
            let state = appState()
            state.openHomeLink(.feature(feature))
            await settle(state, expected)
            assertLanding(state, expected, "\(feature)")
        }
        for feature in ReadinessFeature.allCases where InboxRoute.forFeature(feature, today: Self.today) == nil {
            XCTAssertNotNil(AppState.homeDestination(for: feature), "\(feature) keeps its tab")
        }
    }

    // MARK: - Folders (inbox builder B)

    /// The root and Needs approval as migration 00181 seeds them (the
    /// generated test schema holds no rows), plus one owner folder.
    private func seedFolders() async throws -> (approvals: Int64, owner: Int64) {
        try await manager.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_folders (kind, parent_id, slug, title, position) VALUES ('root', NULL, 'inbox', 'Inbox', 0)
                """)
            let root = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO inbox_folders (kind, parent_id, slug, title, position)
                VALUES ('approvals', ?, 'needs-approval', 'Needs approval', 0)
                """, arguments: [root])
            let approvals = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO inbox_folders (kind, parent_id, slug, title, position) VALUES ('owner', ?, 'release', 'Release', 1)
                """, arguments: [root])
            let owner = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO inbox_folder_state (id, revision) VALUES (1, 1)")
            return (approvals, owner)
        }
    }

    /// A route naming a folder opens it; one naming a folder that was
    /// deleted meanwhile (an old link, a built-in's stale route) opens the root.
    func testRouteToDeletedFolderOpensRoot() async throws {
        let ids = try await seedFolders()
        let state = appState()
        await state.openInbox(InboxRoute(folderID: ids.owner))?.value
        assertLanding(state, Landing(folder: ids.owner), "a folder that exists")

        await state.openInbox(InboxRoute(folderID: 9_999))?.value
        assertLanding(state, Landing(), "a deleted folder opens the root")
    }

    /// The menu's pick is remembered in `inbox.folder` and opens again in a
    /// new view model; a remembered folder that was deleted opens the root.
    /// A route's folder is never remembered.
    func testRememberedFolderOpensAgainAndADeletedOneOpensTheRoot() async throws {
        let ids = try await seedFolders()
        let state = appState()
        let vm = try XCTUnwrap(state.actionStripViewModel)
        await vm.refresh()
        vm.selectFolder(ids.owner)
        XCTAssertEqual(UserDefaults.standard.object(forKey: ActionStripViewModel.folderKey) as? Int64, ids.owner)

        let next = AppState.isolated()
        next.databaseManager = manager
        next.initActionStrip(dbPool: manager.dbPool)
        await next.actionStripViewModel?.refresh()
        XCTAssertEqual(landing(next), Landing(folder: ids.owner), "the pick opens again")

        await next.openInbox(InboxRoute(folderID: ids.approvals))?.value
        XCTAssertEqual(UserDefaults.standard.object(forKey: ActionStripViewModel.folderKey) as? Int64, ids.owner,
                       "a route's folder is not remembered")

        UserDefaults.standard.set(Int64(9_999), forKey: ActionStripViewModel.folderKey)
        let stale = AppState.isolated()
        stale.databaseManager = manager
        stale.initActionStrip(dbPool: manager.dbPool)
        await stale.actionStripViewModel?.refresh()
        XCTAssertEqual(landing(stale), Landing(), "a deleted folder opens the root")
    }

    /// A value the filter bar left in `inbox.filter` is never read: the
    /// Inbox opens on the root with no legacy list.
    func testOldInboxFilterValueOpensTheRoot() async throws {
        UserDefaults.standard.set("tracks", forKey: Self.oldFilterKey)
        let state = appState()
        let vm = try XCTUnwrap(state.actionStripViewModel)
        await vm.refresh()
        XCTAssertEqual(landing(state), Landing())
        XCTAssertTrue(vm.sections.isEmpty)
    }

    /// A built-in card's Show in Inbox opens the folder its artifacts land
    /// in: its route when the owner moved it, else its default folder.
    func testBuiltinShowInInboxOpensItsFolder() async throws {
        let ids = try await seedFolders()
        let automation = try await manager.dbPool.write { db in try TestDatabase.insertAutomation(db) }
        let state = appState()
        await state.openBuiltinInInbox(automationID: automation, defaultFolder: "needs-approval")?.value
        assertLanding(state, Landing(folder: ids.approvals), "the default folder")

        try await manager.dbPool.write { db in
            try db.execute(sql: "INSERT INTO inbox_folder_routes (automation_id, folder_id) VALUES (?, ?)",
                           arguments: [automation, ids.owner])
        }
        await state.openBuiltinInInbox(automationID: automation, defaultFolder: "needs-approval")?.value
        assertLanding(state, Landing(folder: ids.owner), "the route the owner set")

        await state.openBuiltinInInbox(automationID: automation + 1, defaultFolder: "inbox")?.value
        assertLanding(state, Landing(), "the root")
    }
}

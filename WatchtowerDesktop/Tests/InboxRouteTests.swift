import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Briefings, Day Plan, Tracks and Ideas left the sidebar for the Inbox's
/// filters (C1 Task 11): every old way in — a `watchtower-nav://` link, the
/// four navigate helpers, Home — lands on the Inbox with the filter and the
/// card, and nothing does while the Inbox itself is hidden.
@MainActor
final class InboxRouteTests: XCTestCase {
    private static let today = AppState.inboxToday()
    private var manager: DatabaseManager!
    private var path = ""
    private var savedFilter: Any?

    override func setUp() async throws {
        (manager, path) = try TestDatabase.createDatabaseManager()
        // `initActionStrip` keeps the filter in the standard defaults: each
        // view model starts on All, so a landing is the route's own.
        savedFilter = UserDefaults.standard.object(forKey: "inbox.filter")
        UserDefaults.standard.removeObject(forKey: "inbox.filter")
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedFilter, forKey: "inbox.filter")
        TestDatabase.cleanup(path: path)
        manager = nil
    }

    /// An AppState on the test database with the Inbox's view model.
    private func appState(connected: ConnectedSources = .all) -> AppState {
        UserDefaults.standard.removeObject(forKey: "inbox.filter")
        let state = AppState.isolated()
        state.databaseManager = manager
        state.featureVisibility.connectedSources = connected
        state.initActionStrip(dbPool: manager.dbPool)
        state.selectedDestination = .home
        return state
    }

    private func landing(_ state: AppState) -> (SidebarDestination, InboxFilter?, InboxSelection?) {
        (state.selectedDestination, state.actionStripViewModel?.filter, state.actionStripViewModel?.selection)
    }

    private func assertLanding(
        _ state: AppState,
        _ filter: InboxFilter,
        _ selection: InboxSelection?,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let (destination, shownFilter, shownSelection) = landing(state)
        XCTAssertEqual(destination, .inbox, message, file: file, line: line)
        XCTAssertEqual(shownFilter, filter, message, file: file, line: line)
        XCTAssertEqual(shownSelection, selection, message, file: file, line: line)
    }

    /// Waits (bounded) for a fire-and-forget route — a nav link, a Home
    /// click — to finish its Inbox read and selection.
    private func settle(_ state: AppState, _ filter: InboxFilter, _ selection: InboxSelection?) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let vm = state.actionStripViewModel
            if vm?.filter == filter, vm?.selection == selection { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Old nav hosts

    func testOldNavHostsRouteToInboxFilters() async throws {
        let cases: [(String, InboxFilter, InboxSelection?)] = [
            ("briefings", .day, .day(Self.today)),
            ("dayPlan", .day, .day(Self.today)),
            ("day-plan", .day, .day(Self.today)),
            ("tracks", .tracks, nil),
            ("ideas", .ideas, nil)
        ]
        XCTAssertEqual(Set(InboxRoute.aliasHosts.keys), Set(cases.map(\.0)))
        for (host, filter, selection) in cases {
            XCTAssertEqual(InboxRoute.fromNavHost(host, today: Self.today), InboxRoute(filter: filter, selection: selection))
            let state = appState()
            state.isHelpChatShown = true
            XCTAssertTrue(state.visibleHelpScreenIDs.contains(host), host)
            state.openNavLink(NavLink.url(host))
            await settle(state, filter, selection)
            assertLanding(state, filter, selection, host)
            XCTAssertFalse(state.isHelpChatShown, "\(host): the popup closes")
        }
    }

    /// F16: a stored raw value of a removed destination (a `sidebar.hiddenItems`
    /// entry, an old chat answer's link) decodes to no destination and opens
    /// the Inbox filter instead — it never crashes or lands on a ghost tab.
    func testPersistedOldDestinationDecodesToTheInbox() async throws {
        let expected: [String: InboxFilter] = ["briefings": .day, "dayPlan": .day, "ideas": .ideas, "tracks": .tracks]
        for (raw, filter) in expected {
            XCTAssertNil(SidebarDestination(rawValue: raw), raw)
            XCTAssertEqual(InboxRoute.fromNavHost(raw, today: Self.today)?.filter, filter, raw)
            let state = appState()
            state.openNavLink(NavLink.url(raw))
            XCTAssertEqual(state.selectedDestination, .inbox, raw)
        }
        // A hidden-items entry naming one is ignored: FOCUS shows Catch Up and Inbox.
        XCTAssertEqual(SidebarSection.today.partition(hidden: Set(expected.keys)).visible, [.catchUp, .inbox])
    }

    func testOldNavHostIgnoredWhileInboxHidden() {
        for host in InboxRoute.aliasHosts.keys {
            let state = appState(connected: .none)
            XCTAssertFalse(state.visibleHelpScreenIDs.contains(host), host)
            state.openNavLink(NavLink.url(host))
            XCTAssertEqual(state.selectedDestination, .home, host)
        }
    }

    /// F17: no way in moves to a hidden Inbox.
    func testOpenInboxIsANoOpWhileInboxHidden() {
        let state = appState(connected: .none)
        XCTAssertNil(state.openInbox(InboxRoute(filter: .tracks)))
        XCTAssertNil(state.navigateToTrack(3))
        XCTAssertNil(state.navigateToIdea(4))
        XCTAssertNil(state.navigateToDayPlan())
        XCTAssertNil(state.navigateToBriefing(2))
        XCTAssertEqual(state.selectedDestination, .home)
        XCTAssertEqual(state.actionStripViewModel?.selection, nil)
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
        XCTAssertNil(InboxCardLinkPolicy.route(url, navScreens: appState(connected: .none).visibleHelpScreenIDs))
    }

    // MARK: - Navigate helpers

    func testNavigateHelpersOpenTheirCard() async throws {
        let briefingDate = "2026-10-20"
        let briefingID = try await manager.dbPool.write { db -> Int in
            // A day card exists for the date the day-plan route opens.
            try TestDatabase.insertDayPlan(db, planDate: "2026-10-19")
            try TestDatabase.insertBriefing(db, date: briefingDate)
            return Int(db.lastInsertedRowID)
        }

        var state = appState()
        await state.navigateToIdea(5)?.value
        assertLanding(state, .ideas, .idea(5), "idea")

        state = appState()
        await state.navigateToTrack(7)?.value
        assertLanding(state, .tracks, .track(7), "track")

        state = appState()
        await state.navigateToDayPlan("2026-10-19")?.value
        assertLanding(state, .day, .day("2026-10-19"), "day plan of a date")

        state = appState()
        await state.navigateToDayPlan()?.value
        assertLanding(state, .day, .day(Self.today), "today's day plan")

        state = appState()
        await state.navigateToBriefing(briefingID)?.value
        assertLanding(state, .day, .day(briefingDate), "a briefing opens its own day")

        state = appState()
        await state.navigateToBriefing(99_999)?.value
        assertLanding(state, .day, .day(Self.today), "a vanished briefing opens today")
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
        await settle(state, .day, .day(date))
        assertLanding(state, .day, .day(date), "brief")

        let plan = appState()
        plan.openHomeLink(.feature(.dayPlan))
        await settle(plan, .day, .day(Self.today))
        assertLanding(plan, .day, .day(Self.today), "plan")
    }

    /// The brief and plan links show while the Inbox does and their feature is on.
    func testHomeBriefAndPlanLinksFollowTheInboxAndTheirFeature() {
        let state = appState()
        XCTAssertTrue(state.homeLinksAllowed.isSuperset(of: [.briefing, .dayPlan]))
        state.featureVisibility.disabledFeatureIDs = ["briefing"]
        XCTAssertFalse(state.homeLinksAllowed.contains(.briefing))
        XCTAssertTrue(state.homeLinksAllowed.contains(.dayPlan))
        let hidden = appState(connected: .none)
        XCTAssertFalse(hidden.homeLinksAllowed.contains(.briefing))
        XCTAssertFalse(hidden.homeLinksAllowed.contains(.dayPlan))
    }

    func testGettingReadyOpenForTheFourFeatures() async {
        let cases: [(ReadinessFeature, InboxFilter, InboxSelection?)] = [
            (.briefing, .day, .day(Self.today)),
            (.dayPlan, .day, .day(Self.today)),
            (.tracks, .tracks, nil),
            (.ideas, .ideas, nil)
        ]
        for (feature, filter, selection) in cases {
            XCTAssertEqual(InboxRoute.forFeature(feature, today: Self.today), InboxRoute(filter: filter, selection: selection))
            XCTAssertNil(AppState.homeDestination(for: feature), "\(feature) has no tab of its own")
            let state = appState()
            state.openHomeLink(.feature(feature))
            await settle(state, filter, selection)
            assertLanding(state, filter, selection, "\(feature)")
        }
        for feature in ReadinessFeature.allCases where InboxRoute.forFeature(feature, today: Self.today) == nil {
            XCTAssertNotNil(AppState.homeDestination(for: feature), "\(feature) keeps its tab")
        }
    }
}

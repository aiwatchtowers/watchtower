import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Every Home click lands on its tab or item through the existing navigation
/// helpers (`AppState.openHomeLink`), and the Calendar tab consumes the one
/// new deep link — a calendar event — exactly once.
@MainActor
final class HomeLinkTests: XCTestCase {
    private struct Landing: Equatable {
        var destination: SidebarDestination
        var targetID: Int?
        var briefingID: Int?
        var workbenchRoute: WorkbenchRoute?
        var calendarEventID: String?
    }

    private func landing(_ appState: AppState) -> Landing {
        Landing(
            destination: appState.selectedDestination,
            targetID: appState.pendingTargetID,
            briefingID: appState.pendingBriefingID,
            workbenchRoute: appState.pendingWorkbenchRoute,
            calendarEventID: appState.pendingCalendarEventID
        )
    }

    func testEveryLinkLandsOnItsTab() {
        let route = WorkbenchRoute(projectID: 3, pane: .board)
        let cases: [(HomeLink, Landing)] = [
            (.inbox, Landing(destination: .inbox)),
            (.calendarEvent(id: "evt-acme"), Landing(destination: .calendar, calendarEventID: "evt-acme")),
            (.briefing(id: 7), Landing(destination: .briefings, briefingID: 7)),
            (.targets, Landing(destination: .targets)),
            (.target(id: 11), Landing(destination: .targets, targetID: 11)),
            (.workbench(route), Landing(destination: .workbench, workbenchRoute: route)),
            (.workbenches, Landing(destination: .workbench)),
            (.catchUp, Landing(destination: .catchUp)),
            (.feature(.tracks), Landing(destination: .tracks)),
            (.feature(.jira), Landing(destination: .boards)),
            (.turnOn(featureID: "slack-digests"), Landing(destination: .home))
        ]
        for (link, expected) in cases {
            let appState = AppState.isolated()
            appState.selectedDestination = .home
            appState.openHomeLink(link)
            XCTAssertEqual(landing(appState), expected, "\(link)")
        }
    }

    func testAskLinkCarriesTheRoute() {
        let appState = AppState.isolated()
        let route = WorkbenchRoute.forAsk(projectID: 2, sessionID: nil, askID: 9)
        appState.openHomeLink(.workbench(route))
        XCTAssertEqual(appState.pendingWorkbenchRoute, route)
        XCTAssertEqual(appState.pendingWorkbenchRoute?.pane, .board, "no live session → the board")
        XCTAssertEqual(appState.selectedDestination, .workbench)
    }

    /// #575: a card's Turn on goes through the empty states' Turn on
    /// (`features enable` + one restart), not a tab.
    func testTurnOnRunsTheEmptyStateTurnOn() async {
        let row = """
            {"id":"slack-digests","title":"Slack Digests","description":"d","tagline":"t","benefits":[],"icon":"i",\
            "state":"disabled","core":false,"parent":"","config_key":"digest.enabled",\
            "cost":"heavy","feeds_into":[],"sub_toggles":[]}
            """
        let runner = FakeCLIRunner(stdout: Data("{\"features\":[\(row)]}".utf8))
        let appState = AppState.isolated(featuresRunner: runner)
        appState.selectedDestination = .home
        appState.openHomeLink(.turnOn(featureID: "slack-digests"))
        for _ in 0..<2000 where !runner.invocations.contains(["features", "enable", "slack-digests"]) {
            await Task.yield()
        }
        XCTAssertTrue(runner.invocations.contains(["features", "enable", "slack-digests"]))
        XCTAssertEqual(appState.selectedDestination, .home)
    }

    func testConnectOpensConnections() {
        let appState = AppState.isolated()
        appState.selectedDestination = .home
        appState.settingsTab = .system
        var opened = 0
        appState.openSettingsWindow = { opened += 1 }
        appState.openHomeLink(.connect(.calendar))
        XCTAssertEqual(appState.settingsTab, .connections)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(appState.selectedDestination, .home, "Connect opens Settings, not a tab")
    }

    /// Jira connected with no board picked (#572): the action opens the Boards
    /// tab, where the board switches are, not Settings.
    func testChooseJiraBoardsOpensBoards() {
        let appState = AppState.isolated()
        appState.selectedDestination = .home
        var opened = 0
        appState.openSettingsWindow = { opened += 1 }
        appState.openHomeLink(.connect(.jiraBoards))
        XCTAssertEqual(appState.selectedDestination, .boards)
        XCTAssertEqual(opened, 0)
    }

    /// Each feature opens a tab whose empty state is about that feature (or
    /// its sibling: stream digests on Digests, Linear on Blockers, whose row
    /// speaks for both trackers, Jira on its views); Knowledge
    /// search opens Search, which keeps its own empty state.
    func testEveryFeatureHasADestination() {
        let siblings: [ReadinessFeature: ReadinessFeature] = [.streamDigests: .digests, .linear: .jira]
        for feature in ReadinessFeature.allCases {
            let destination = AppState.homeDestination(for: feature)
            guard let copy = EmptyStateCopyTable.copy(for: destination.rawValue, briefingHour: 8, dayPlanHour: 9),
                  let copyFeature = copy.feature else {
                XCTAssertEqual(feature, .knowledgeIndex, "\(feature) → \(destination) has no empty state")
                XCTAssertEqual(destination, .search)
                continue
            }
            XCTAssertEqual(copyFeature, siblings[feature] ?? feature, "\(feature) → \(destination)")
        }
    }

    func testCalendarPendingEventIsConsumedOnce() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let start = Date().addingTimeInterval(3600)
        let iso = ISO8601DateFormatter()
        let title = "Acme roadmap sync"
        try await manager.dbPool.write { db in
            try TestDatabase.insertCalendarAccount(db)
            try TestDatabase.insertCalendarEvent(
                db, id: "evt-acme", title: title,
                startTime: iso.string(from: start), endTime: iso.string(from: start.addingTimeInterval(1800)))
        }
        let appState = AppState.isolated()
        appState.databaseManager = manager
        appState.initCalendar(dbPool: manager.dbPool)
        defer { appState.calendarViewModel?.stopObserving() }
        appState.initCalendarAccounts(dbPool: manager.dbPool)
        await appState.calendarAccountsViewModel?.refreshAsync()

        let probe = ViewRenderProbe(size: NSSize(width: 1000, height: 600))
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let listOnly = try probe.render(CalendarEventsView().environment(appState), aqua)

        appState.navigateToCalendarEvent("evt-acme")
        let linked = try probe.render(CalendarEventsView().environment(appState), aqua)

        XCTAssertNil(appState.pendingCalendarEventID, "consumed by the Calendar tab")
        // The selected meeting opens its detail pane on the right, where the
        // list alone paints only its own rows.
        var changed = 0
        for x in stride(from: 700, to: 1000, by: 10) {
            for y in stride(from: 0, to: 600, by: 10)
            where try probe.pixel(listOnly, x: x, y: y) != probe.pixel(linked, x: x, y: y) {
                changed += 1
            }
        }
        XCTAssertGreaterThan(changed, 20, "the detail pane is open")
    }
}

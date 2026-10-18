import XCTest
import SwiftUI
import ViewInspector
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// Each AI-output tab's no-data branch renders the shared `FeatureEmptyState`
/// with the tab's copy, keeping its own content inside. The tab views read
/// `@Environment(AppState.self)`, which ViewInspector can't populate, so
/// these drive the environment-free pieces those views render.
@MainActor
final class EmptyStateTabWiringTests: XCTestCase {
    private static let known = Owner(
        id: "1:U1", source: .slack, slackUserID: "1:U1", email: "", jiraAccountID: "", displayName: "Me"
    )
    private var context: EmptyStateContext {
        var context = EmptyStateContext()
        context.readiness = { _ in .scheduled(.nextCycle(minutes: 15)) }
        return context
    }
    private var dbPath = ""

    override func tearDown() {
        if !dbPath.isEmpty { TestDatabase.cleanup(path: dbPath) }
        super.tearDown()
    }

    private func copy(_ destination: SidebarDestination) throws -> EmptyStateCopy {
        try XCTUnwrap(EmptyStateCopyTable.copy(for: destination.rawValue, briefingHour: 8, dayPlanHour: 8))
    }

    private func assertSharedState<V: View>(
        _ view: V, _ destination: SidebarDestination, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let copy = try copy(destination)
        XCTAssertNoThrow(try view.inspect().find(text: copy.title), file: file, line: line)
        XCTAssertNoThrow(try view.inspect().find(text: copy.landsHere), file: file, line: line)
        // A tab with no pipeline (Targets, Workbench) has no readiness line.
        guard copy.feature != nil else { return }
        XCTAssertNoThrow(try view.inspect().find(text: "Within ~15 min"), "the readiness line", file: file, line: line)
    }

    func testBriefingsEmptyUsesSharedState() throws {
        let view = BriefingsEmptyState(
            owner: Self.known, isGenerating: false, generateError: nil,
            onGenerate: {}, onOpenConnections: {}, context: context)
        try assertSharedState(view, .briefings)
        XCTAssertThrowsError(try view.inspect().find(text: "Briefings are generated daily after sync completes."))
        XCTAssertNoThrow(try view.inspect().find(text: "Generate Briefing"))
    }

    func testDayPlanEmptyUsesSharedState() throws {
        try assertSharedState(DayPlanEmptyState(owner: Self.known, context: context) {}, .dayPlan)
        // OWNER-02 stays inside: no owner → the way to connect one.
        let noOwner = DayPlanEmptyState(owner: .unknown, context: context) {}
        XCTAssertNoThrow(try noOwner.inspect().find(button: "Open Connections"))
    }

    /// An established install (day plan rows exist) with no plan for today
    /// yet gets a calm line, not the first-run screen (owner, ask #299).
    func testDayPlanEstablishedWithoutTodaysPlanSaysWhen() throws {
        var established = context
        established.readiness = { _ in .ready }
        established.dayPlanHour = 8
        let view = DayPlanEmptyState(owner: Self.known, context: established) {}
        XCTAssertNoThrow(try view.inspect().find(text: "Today's plan at or after 08:00"))
        XCTAssertThrowsError(try view.inspect().find(text: try copy(.dayPlan).title), "not the first-run screen")

        established.dayPlanHour = 10
        let later = DayPlanEmptyState(owner: Self.known, context: established) {}
        XCTAssertNoThrow(try later.inspect().find(text: "Today's plan at or after 10:00"), "the configured hour")

        // No owner: the daemon makes no plan, so no time is promised.
        let noOwner = DayPlanEmptyState(owner: .unknown, context: established) {}
        XCTAssertThrowsError(try noOwner.inspect().find(text: "Today's plan at or after 10:00"))
        XCTAssertNoThrow(try noOwner.inspect().find(button: "Open Connections"))

        // A fresh install keeps the first-run copy.
        let fresh = DayPlanEmptyState(owner: Self.known, context: context) {}
        XCTAssertNoThrow(try fresh.inspect().find(text: try copy(.dayPlan).title))
        XCTAssertThrowsError(try fresh.inspect().find(text: "Today's plan at or after 08:00"))
    }

    func testPeopleEmptyUsesSharedState() throws {
        try assertSharedState(PeopleListView.emptyState(context: context), .people)
    }

    func testDigestsEmptyUsesSharedState() throws {
        XCTAssertEqual(DigestListView.emptyKind(feedIsEmpty: true, visibleIsEmpty: true), .noData)
        try assertSharedState(DigestListView.emptyFeed(.noData, context: context), .digests)

        // Digests exist but the search (or the unread filter) hides them all.
        XCTAssertEqual(DigestListView.emptyKind(feedIsEmpty: false, visibleIsEmpty: true), .noMatches)
        let noMatches = DigestListView.emptyFeed(.noMatches, context: context)
        XCTAssertNoThrow(try noMatches.inspect().find(text: "No matches"))
        XCTAssertThrowsError(try noMatches.inspect().find(text: try copy(.digests).title))
        XCTAssertNil(DigestListView.emptyKind(feedIsEmpty: false, visibleIsEmpty: false))
    }

    func testTracksEmptyUsesSharedState() throws {
        try assertSharedState(TracksListView.emptyState(context: context), .tracks)
    }

    func testIdeasEmptyUsesSharedState() throws {
        var found = false
        let view = IdeasView.emptyState(context: context, onFindIdeas: { found = true }, onCreate: {}, badge: { EmptyView() })
        try assertSharedState(view, .ideas)
        // The fresh-install backfill and Create stay reachable.
        try view.inspect().find(text: "Find Ideas").find(ViewType.Button.self, relation: .parent).tap()
        XCTAssertTrue(found)
        XCTAssertNoThrow(try view.inspect().find(text: "Create"))
    }

    func testMemoryEmptyVaultUsesSharedState() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        dbPath = path
        let vm = MemoryViewModel(dbPool: manager.dbPool)
        XCTAssertFalse(vm.vaultExists)
        try assertSharedState(MemoryView(vm: vm, emptyState: context), .memory)

        // The search-empty state inside an existing vault is unchanged.
        let vault = (path as NSString).deletingLastPathComponent + "/memory"
        try FileManager.default.createDirectory(atPath: vault, withIntermediateDirectories: true)
        vm.searchText = "nothing-matches-this"
        let searching = MemoryView(vm: vm, emptyState: context)
        XCTAssertNoThrow(try searching.inspect().find(text: "No matches"))
        XCTAssertThrowsError(try searching.inspect().find(text: try copy(.memory).title))
    }

    func testCatchUpEmptyKeepsFirstSyncLine() throws {
        var built = false
        let view = CatchUpView.emptyPane(
            firstSync: FirstSyncLine(title: "Syncing Slack…", detail: "Messages · 3/10 channels"),
            context: context
        ) { built = true }
        try assertSharedState(view, .catchUp)
        XCTAssertNoThrow(try view.inspect().find(text: "Syncing Slack…"))
        try view.inspect().find(button: "Build a recap").tap()
        XCTAssertTrue(built)
    }

    // MARK: - Source and work tabs

    private func withReadiness(_ readiness: Readiness) -> EmptyStateContext {
        var context = EmptyStateContext()
        context.readiness = { _ in readiness }
        return context
    }

    /// #575: the Tracks tab's Turn on, progress and error are Slack
    /// Digests' while it waits on it, and its error and retry stay after a
    /// failed restart moved the state on (review F1).
    func testTracksTabTurnsOnSlackDigests() throws {
        var performed: EmptyStateAction?
        var context = withReadiness(.needsDigests)
        context.isTurningOn = { $0 == "slack-digests" }
        context.perform = { performed = $0 }
        let waiting = TabEmptyState(.tracks, context: context)
        XCTAssertNoThrow(try waiting.inspect().find(text: "Needs Slack Digests"))
        let button = try waiting.inspect().find(button: "Turn on Slack Digests")
        XCTAssertTrue(button.isDisabled(), "progress is keyed by slack-digests")
        XCTAssertNoThrow(try waiting.inspect().find(ViewType.ProgressView.self))

        context = withReadiness(.scheduled(.nextCycle(minutes: 15)))
        context.turnOnError = { $0 == "slack-digests" ? "boom" : nil }
        context.perform = { performed = $0 }
        let failed = TabEmptyState(.tracks, context: context)
        XCTAssertNoThrow(try failed.inspect().find(text: "boom"))
        try failed.inspect().find(button: "Try again").tap()
        XCTAssertEqual(performed, .turnOn(featureID: "slack-digests"))
    }

    func testCalendarEmptyOffersConnect() throws {
        var performed: EmptyStateAction?
        var context = withReadiness(.needsSource(.calendar))
        context.perform = { performed = $0 }
        let view = CalendarEventsView.notConnectedState(context: context) { Text("google") }
        let copy = try copy(.calendar)
        XCTAssertNoThrow(try view.inspect().find(text: copy.title))
        try view.inspect().find(button: "Connect a calendar").tap()
        XCTAssertEqual(performed, .connect(.calendar))
        XCTAssertNoThrow(try view.inspect().find(text: "google"), "the in-place connect options stay")

        // Connected and synced but nothing upcoming: the tab's own line, not "connect".
        let noEvents = CalendarEventsView.noEventsState(context: withReadiness(.ready))
        XCTAssertNoThrow(try noEvents.inspect().find(text: "No upcoming events"))
        let scheduled = withReadiness(.scheduled(.nextCycle(minutes: 15)))
        try assertSharedState(CalendarEventsView.noEventsState(context: scheduled), .calendar)
    }

    func testStatisticsEmptyNoLongerSaysNoData() throws {
        let views: [AnyView] = [
            AnyView(ActivityStatisticsView.emptyState(context: context)),
            AnyView(ChannelStatisticsView.emptyState(context: context)),
            AnyView(UserStatisticsView.emptyState(context: context))
        ]
        for view in views {
            try assertSharedState(view, .statistics)
            XCTAssertThrowsError(try view.inspect().find(text: "No data"))
        }
    }

    func testWorkloadEmptyOffersConnectJira() throws {
        let view = WorkloadView.emptyState(hasEntries: false, context: withReadiness(.needsSource(.jira)))
        XCTAssertNoThrow(try view.inspect().find(text: try copy(.workload).title))
        XCTAssertNoThrow(try view.inspect().find(button: "Connect Jira"))
        XCTAssertThrowsError(try view.inspect().find(text: "No workload data"))
        // Entries hidden by the search or a signal filter: not "no data".
        let filtered = WorkloadView.emptyState(hasEntries: true, context: context)
        XCTAssertNoThrow(try filtered.inspect().find(text: "No matches"))
    }

    func testJiraTabsEmptyUseSharedState() throws {
        try assertSharedState(BlockerMapView.emptyState(context: context), .blockers)
        try assertSharedState(ProjectMapView.emptyState(isFiltered: false, context: context), .projectMap)
        try assertSharedState(ReleaseDashboardView.emptyState(isFiltered: false, context: context), .releases)
        // Boards knows Jira isn't connected: its readiness line says so whatever the center read.
        let boards = BoardsView.notConnectedState(context: context)
        XCTAssertNoThrow(try boards.inspect().find(text: try copy(.boards).landsHere))
        XCTAssertNoThrow(try boards.inspect().find(text: "Connect Jira to get this"))

        // Jira data present: no blockers is good news, said in the tab's own words.
        XCTAssertNoThrow(try BlockerMapView.emptyState(context: withReadiness(.ready)).inspect().find(text: "No blockers"))
        // Blockers read Linear too: Linear data alone is enough, and a
        // Linear-only install is not asked to connect Jira.
        var linearOnly = EmptyStateContext()
        linearOnly.readiness = { $0 == .linear ? .ready : .needsSource(.jira) }
        XCTAssertNoThrow(try BlockerMapView.emptyState(context: linearOnly).inspect().find(text: "No blockers"))
        var linearSyncing = EmptyStateContext()
        linearSyncing.readiness = { $0 == .linear ? .scheduled(.nextCycle(minutes: 15)) : .needsSource(.jira) }
        let syncing = BlockerMapView.emptyState(context: linearSyncing)
        XCTAssertThrowsError(try syncing.inspect().find(button: "Connect Jira"))
        XCTAssertNoThrow(try syncing.inspect().find(text: "Within ~15 min"))
        // A search that hides everything keeps its own state.
        let searched = ProjectMapView.emptyState(isFiltered: true, context: context)
        XCTAssertNoThrow(try searched.inspect().find(text: "No matching epics"))
        let searchedReleases = ReleaseDashboardView.emptyState(isFiltered: true, context: context)
        XCTAssertNoThrow(try searchedReleases.inspect().find(text: "No matching releases"))
    }

    func testTargetsEmptyUsesSharedState() throws {
        var created = false
        let view = TargetsListView.emptyState(context: context) { created = true }
        try assertSharedState(view, .targets)
        try view.inspect().find(button: "New target").tap()
        XCTAssertTrue(created)
        XCTAssertNoThrow(try view.inspect().find(text: TargetsListView.reactionHint))
        XCTAssertTrue(TargetsListView.reactionHint.contains("React with an emoji in Slack"))
    }

    func testWorkbenchEmptyOffersAddFolder() throws {
        var added = false
        let view = WorkbenchesView.emptyState(
            hasWorkbenches: false, agentName: "Claude Code", context: context
        ) { added = true }
        let copy = try copy(.workbench)
        XCTAssertNoThrow(try view.inspect().find(text: copy.title))
        try view.inspect().find(button: "Add a folder").tap()
        XCTAssertTrue(added)
        // Workbenches exist, none picked: the tab's own hint.
        let picking = WorkbenchesView.emptyState(hasWorkbenches: true, agentName: "Claude Code", context: context) {}
        XCTAssertThrowsError(try picking.inspect().find(text: copy.title))
        XCTAssertNoThrow(try picking.inspect().find(text: "Pick a folder to start a workbench. Claude Code sets it up from there."))
    }

    func testInboxEmptyKeepsCheatSheet() throws {
        let (pool, path) = try TestDatabase.createPool()
        dbPath = path
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        let view = ActionStripActionsView(
            vm: vm, cheatSheetRows: [], feature: .on(lastCheck: nil), isEnabling: false, featureError: nil,
            onEnable: {}, onOpenSettings: {}, onOpen: { _ in }, emptyState: context)
        try assertSharedState(view, .inbox)
        XCTAssertNoThrow(try view.inspect().find(ReactionCheatSheetView.self))
    }

    func testBoardsNotConnectedShowsConnectWithNilReadiness() throws {
        var performed: EmptyStateAction?
        var neutral = EmptyStateContext.neutral
        neutral.perform = { performed = $0 }
        for context in [neutral, withReadiness(.ready)] {
            let view = BoardsView.notConnectedState(context: context)
            XCTAssertNoThrow(try view.inspect().find(text: try copy(.boards).title))
            try view.inspect().find(button: "Connect Jira").tap()
        }
        XCTAssertEqual(performed, .connect(.jira))
    }
}

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
        try assertSharedState(DayPlanView.emptyState(owner: Self.known, context: context) {}, .dayPlan)
        // OWNER-02 stays inside: no owner → the way to connect one.
        let noOwner = DayPlanView.emptyState(owner: .unknown, context: context) {}
        XCTAssertNoThrow(try noOwner.inspect().find(button: "Open Connections"))
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
            firstSync: (title: "Syncing Slack…", detail: "Messages · 3/10 channels"),
            context: context
        ) { built = true }
        try assertSharedState(view, .catchUp)
        XCTAssertNoThrow(try view.inspect().find(text: "Syncing Slack…"))
        try view.inspect().find(button: "Build a recap").tap()
        XCTAssertTrue(built)
    }
}

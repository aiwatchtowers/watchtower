import XCTest
import GRDB
import SwiftUI
import ViewInspector
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// OWNER-02 on the Desktop: with no owner identity, the Inbox's day card
/// (the Briefings and Day Plan screens until C1, the Day filter until
/// inbox builder B) shows `NoOwnerEmptyState`, and offers no Generate,
/// Regenerate or Reset. The guards keep their names; since C1 Task 11 they
/// drive the Inbox pieces that replaced those screens:
/// `ActionStripActionsView` on the root and the day
/// card's `InboxDayPlanBlock`. `ActionStripView` reads
/// `@Environment(AppState.self)`, which ViewInspector cannot populate (see
/// `TrayMenuViewTests`), so these drive the environment-free pieces.
@MainActor
final class NoOwnerEmptyStateViewTests: XCTestCase {
    private static let known = Owner(
        id: "1:U1", source: .slack, slackUserID: "1:U1", email: "", jiraAccountID: "", displayName: "Me"
    )
    private static let message = "Connect Slack, Google, Jira, Linear or an email account so Watchtower knows who you are"

    // MARK: - NoOwnerEmptyState

    func testOwner02EmptyStateTextAndOpenConnections() throws {
        var opened = false
        let view = NoOwnerEmptyState { opened = true }

        XCTAssertNoThrow(try view.inspect().find(text: Self.message))
        try view.inspect().find(button: "Open Connections").tap()
        XCTAssertTrue(opened)
    }

    // MARK: - Briefings (the Inbox's day card)

    func testOwner02BriefingsUnknownOwnerShowsEmptyStateAndNoGenerate() throws {
        let view = try makeDayFilterEmpty(ownerKnown: false)

        XCTAssertNoThrow(try view.inspect().find(text: Self.message))
        XCTAssertNoThrow(try view.inspect().find(button: "Open Connections"))
        XCTAssertThrowsError(try view.inspect().find(button: "Make today's brief and plan"))
    }

    // MARK: - Day Plan (the Inbox's day card)

    func testOwner02DayPlanUnknownOwnerOffersNoGenerate() async throws {
        for hasPlan in [false, true] {
            let block = try await makeDayPlanBlock(owner: .unknown, hasPlan: hasPlan)
            XCTAssertThrowsError(try block.inspect().find(button: "Generate today's plan"))
            XCTAssertThrowsError(try block.inspect().find(button: "Regenerate with feedback…"))
            XCTAssertThrowsError(try block.inspect().find(button: "Reset plan"))
            // The day card's own labels for the same three (C1).
            XCTAssertThrowsError(try block.inspect().find(button: "Make today's plan"))
            XCTAssertThrowsError(try block.inspect().find(button: "Reset plan…"))
        }
    }

    func testDayPlanKnownOwnerOffersGenerateOrRegenerate() async throws {
        XCTAssertNoThrow(try makeDayFilterEmpty(ownerKnown: true).inspect().find(button: "Make today's brief and plan"))
        let empty = try await makeDayPlanBlock(owner: Self.known, hasPlan: false)
        XCTAssertNoThrow(try empty.inspect().find(button: "Make today's plan"))

        let planned = try await makeDayPlanBlock(owner: Self.known, hasPlan: true)
        XCTAssertNoThrow(try planned.inspect().find(button: "Regenerate with feedback…"))
        XCTAssertNoThrow(try planned.inspect().find(button: "Reset plan…"))
    }

    /// The empty state replaces the plan body only when there is no plan to
    /// show: an existing plan stays readable. On the Inbox: with no owner
    /// today's empty card says why; a day with a plan is a Morning brief
    /// entry in the root, listed and readable.
    func testOwner02DayPlanShowsEmptyStateOnlyWithoutOwnerAndPlan() async throws {
        XCTAssertNoThrow(try makeDayFilterEmpty(ownerKnown: false).inspect().find(text: Self.message))
        try await insertTodaysPlan()
        let listed = try await makeDayFilter(ownerKnown: false)
        XCTAssertFalse(Self.days(listed.vm).isEmpty, "the planned day is listed")
        XCTAssertThrowsError(try listed.inspect().find(text: Self.message))
        let readable = try await makeDayPlanBlock(owner: .unknown, hasPlan: true)
        XCTAssertNoThrow(try readable.inspect().find(text: "Standup"), "the plan stays readable")

        XCTAssertThrowsError(try makeDayFilterEmpty(ownerKnown: true).inspect().find(text: Self.message))
        let known = try await makeDayFilter(ownerKnown: true)
        XCTAssertThrowsError(try known.inspect().find(text: Self.message))
    }

    // MARK: - Inbox

    /// The daemon skips the inbox without an owner, so the empty strip says
    /// why (it used to show nothing at all) and opens Connections.
    func testOwner02InboxUnknownOwnerShowsEmptyState() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        // After a read, as the owner sees it: no owner, so the root lists no day card.
        await vm.refresh()
        var opened = false
        let unknown = makeInboxEmpty(vm, ownerKnown: false) { opened = true }

        XCTAssertNoThrow(try unknown.inspect().find(text: Self.message))
        try unknown.inspect().find(button: "Open Connections").tap()
        XCTAssertTrue(opened)
        XCTAssertNoThrow(try unknown.inspect().find(ReactionCheatSheetView.self), "the cheat sheet stays")

        let known = makeInboxEmpty(vm, ownerKnown: true) {}
        XCTAssertThrowsError(try known.inspect().find(text: Self.message))
    }

    /// With an owner and nothing made yet, the root lists today's day card;
    /// with none, the root stays empty and says why (OWNER-02).
    func testInboxRootShowsTodaysCardOnlyWithAnOwner() async throws {
        let suite = "NoOwnerEmptyStateViewTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let vm = ActionStripViewModel(dbPool: try testPool(), cliRunner: FakeCLIRunner(), defaults: defaults)

        await vm.refresh()
        XCTAssertTrue(Self.days(vm).isEmpty, "no owner: no placeholder in the root")
        XCTAssertNoThrow(try makeInboxEmpty(vm, ownerKnown: false) {}.inspect().find(text: Self.message))

        try await testPool().write { db in
            _ = try TestDatabase.insertSlackAccount(db, currentUserID: "1:U1")
        }
        await vm.refresh()
        XCTAssertEqual(Self.days(vm), [AppState.inboxToday()])
        XCTAssertThrowsError(try makeInboxEmpty(vm, ownerKnown: true) {}.inspect().find(text: Self.message))
    }

    /// Today's placeholder obeys Settings → Features: with the briefing and
    /// day-plan features both off the root does not list it; with one off it
    /// is listed and offers to make only the other half.
    func testTodaysPlaceholderObeysTheFeatureSwitches() async throws {
        try await testPool().write { db in
            _ = try TestDatabase.insertSlackAccount(db, currentUserID: "1:U1")
        }
        let vm = try inboxVM()
        let today = AppState.inboxToday()
        vm.disabledFeatures = ["briefing", "day-plan"]
        await vm.refresh()
        XCTAssertTrue(Self.days(vm).isEmpty, "both off: no placeholder in the root")

        vm.disabledFeatures = ["briefing"]
        await vm.refresh()
        XCTAssertEqual(Self.days(vm), [today])
        XCTAssertFalse(vm.feed.briefingOn)
        XCTAssertTrue(vm.feed.dayPlanOn)

        let pool = try testPool()
        func pane(briefingOn: Bool, dayPlanOn: Bool) -> InboxDayNothingReady {
            InboxDayNothingReady(
                owner: Self.known,
                briefing: BriefingViewModel(dbManager: DatabaseManager(pool: pool), cliRunner: FakeCLIRunner()),
                plan: DayPlanViewModel(databasePool: pool, cliRunner: FakeCLIRunner()),
                emptyState: .neutral, briefingOn: briefingOn, dayPlanOn: dayPlanOn,
                onMake: {}, onOpenConnections: {})
        }
        let planOnly = pane(briefingOn: false, dayPlanOn: true)
        XCTAssertNoThrow(try planOnly.inspect().find(button: "Make today's plan"))
        XCTAssertThrowsError(try planOnly.inspect().find(button: "Make today's brief and plan"))
        XCTAssertThrowsError(try planOnly.inspect().find(button: "Make today's brief"))
        let briefOnly = pane(briefingOn: true, dayPlanOn: false)
        XCTAssertNoThrow(try briefOnly.inspect().find(button: "Make today's brief"))
        XCTAssertThrowsError(try briefOnly.inspect().find(button: "Make today's plan"))
    }

    // MARK: - Helpers

    private func makeInboxEmpty(
        _ vm: ActionStripViewModel, ownerKnown: Bool, onOpenConnections: @escaping () -> Void
    ) -> ActionStripActionsView {
        ActionStripActionsView(
            vm: vm, cheatSheetRows: [], feature: .on(lastCheck: nil), isEnabling: false, featureError: nil,
            onEnable: {}, onOpenSettings: {}, onOpen: { _ in },
            onOpenConnections: onOpenConnections, ownerKnown: ownerKnown
        )
    }

    /// A test database per test; the Inbox's view model keeps its
    /// remembered folder in its own defaults suite.
    private var dbPath = ""
    private var pool: DatabasePool?
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        if !dbPath.isEmpty { TestDatabase.cleanup(path: dbPath) }
        super.tearDown()
    }

    private func testPool() throws -> DatabasePool {
        if let pool { return pool }
        let (made, path) = try TestDatabase.createPool()
        pool = made
        dbPath = path
        return made
    }

    private func insertTodaysPlan() async throws {
        let today = AppState.inboxToday()
        try await testPool().write { db in
            let planID = try TestDatabase.insertDayPlan(db, planDate: today)
            try TestDatabase.insertDayPlanItem(db, dayPlanID: planID, kind: "backlog", title: "Standup")
        }
    }

    private func inboxVM() throws -> ActionStripViewModel {
        let suite = "NoOwnerEmptyStateViewTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return ActionStripViewModel(dbPool: try testPool(), cliRunner: FakeCLIRunner(), defaults: defaults)
    }

    /// The dates of the root's Morning brief entries, in list order.
    private static func days(_ vm: ActionStripViewModel) -> [String] {
        vm.folderEntries.compactMap { entry in
            if case let .legacyDay(card) = entry { return card.date }
            return nil
        }
    }

    /// Today's card with nothing made yet: the root lists today's placeholder
    /// card (T11b), whose pane says why with no owner and offers Make
    /// today's brief and plan with one.
    private func makeDayFilterEmpty(ownerKnown: Bool) throws -> InboxDayNothingReady {
        let pool = try testPool()
        return InboxDayNothingReady(
            owner: ownerKnown ? Self.known : .unknown,
            briefing: BriefingViewModel(dbManager: DatabaseManager(pool: pool), cliRunner: FakeCLIRunner()),
            plan: DayPlanViewModel(databasePool: pool, cliRunner: FakeCLIRunner()),
            emptyState: .neutral,
            onMake: {},
            onOpenConnections: {}
        )
    }

    /// The Inbox after a read of what the database holds.
    private func makeDayFilter(ownerKnown: Bool) async throws -> ActionStripActionsView {
        let vm = try inboxVM()
        await vm.refresh()
        return makeInboxEmpty(vm, ownerKnown: ownerKnown) {}
    }

    /// Today's card's plan half, loaded for today (with a plan when `hasPlan`).
    private func makeDayPlanBlock(owner: Owner, hasPlan: Bool) async throws -> InboxDayPlanBlock {
        if hasPlan, try await testPool().read({ try DayPlanQueries.fetchByDate($0, date: AppState.inboxToday()) }) == nil {
            try await insertTodaysPlan()
        }
        let plan = DayPlanViewModel(databasePool: try testPool(), cliRunner: FakeCLIRunner())
        await plan.loadFor(date: AppState.inboxToday())
        if !hasPlan { XCTAssertNil(plan.plan, "precondition: no plan") }
        return InboxDayPlanBlock(plan: plan, isToday: true, owner: owner, openRow: .constant(nil)) { _ in }
    }
}

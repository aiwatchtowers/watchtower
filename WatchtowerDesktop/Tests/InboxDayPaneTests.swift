import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Inbox's Your day card (spec §6.3, R10): the plan on top, the brief
/// below; Add and Regenerate with feedback… only on today's card, both
/// inline rows.
@MainActor
final class InboxDayPaneTests: XCTestCase {
    nonisolated private static let today = "2026-10-22"
    nonisolated private static let yesterday = "2026-10-21"
    nonisolated private static let owner = Owner(
        id: "1:U1", source: .slack, slackUserID: "1:U1", email: "", jiraAccountID: "", displayName: "Me"
    )
    nonisolated private static let attention = #"[{"text":"Reply to the release thread","priority":"high","source_type":"track","source_id":"3"}]"#

    private var pool: DatabaseQueue!
    private var cli: FakeCLIRunner!
    private var plan: DayPlanViewModel!

    override func setUp() async throws {
        pool = try TestDatabase.create()
        cli = FakeCLIRunner()
        plan = DayPlanViewModel(databasePool: pool, cliRunner: cli)
    }

    override func tearDown() async throws {
        plan = nil
        cli = nil
        pool = nil
    }

    // MARK: - Fixtures

    private func insertPlan(date: String, hasConflicts: Bool = false) async throws {
        try await pool.write { db in
            let planID = try TestDatabase.insertDayPlan(
                db, planDate: date, hasConflicts: hasConflicts,
                conflictSummary: hasConflicts ? "Standup overlaps the design review" : nil
            )
            try TestDatabase.insertDayPlanItem(db, dayPlanID: planID, kind: "timeblock", sourceType: "manual",
                                               title: "Standup", startTime: "\(date)T09:00:00Z",
                                               endTime: "\(date)T09:30:00Z")
            try TestDatabase.insertDayPlanItem(db, dayPlanID: planID, kind: "backlog", sourceType: "manual",
                                               title: "Write tests")
        }
    }

    private func insertBriefing(date: String) async throws {
        try await pool.write { db in
            try TestDatabase.insertBriefing(db, date: date, attention: Self.attention)
        }
    }

    /// The card over what the database holds for `date`, with the view model
    /// loaded for it (the pane's `.task` does this on screen).
    private func pane(
        date: String,
        owner: Owner = InboxDayPaneTests.owner,
        onDone: @escaping () -> Void = {},
        onDiscuss: @escaping () -> Void = {}
    ) async throws -> InboxDayPane {
        let (briefing, dayPlan) = try await pool.read { db in
            (try BriefingQueries.fetchByDate(db, date: date), try DayPlanQueries.fetchByDate(db, date: date))
        }
        await plan.loadFor(date: date)
        let card = InboxDayCard(date: date, briefing: briefing, plan: dayPlan,
                                planDone: 0, planTotal: plan.items.count, stamp: Date())
        return InboxDayPane(card: card, today: Self.today, plan: plan, owner: owner,
                            onDone: onDone, onCommand: { _ in }, onOpenSource: { _ in }, onDiscuss: onDiscuss)
    }

    /// The plan block as the pane shows it, with its open row in `row`.
    private func block(row: Binding<InboxDayPlanRow?>, isToday: Bool = true) -> InboxDayPlanBlock {
        InboxDayPlanBlock(plan: plan, isToday: isToday, owner: Self.owner, openRow: row) { _ in }
    }

    private func texts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
    }

    // MARK: - Tests

    func testPlanAboveBriefing() async throws {
        try await insertPlan(date: Self.today)
        try await insertBriefing(date: Self.today)
        let sut = try await pane(date: Self.today)

        let all = try texts(sut)
        let firstRow = try XCTUnwrap(all.firstIndex(of: "Standup"))
        let needsYou = try XCTUnwrap(all.firstIndex(of: "Needs you"))
        XCTAssertLessThan(firstRow, needsYou)
        XCTAssertNoThrow(try sut.inspect().find(text: "Reply to the release thread"))
    }

    func testHeaderButtons() async throws {
        try await insertPlan(date: Self.today)
        var done = 0
        var discussed = 0
        let sut = try await pane(date: Self.today, onDone: { done += 1 }, onDiscuss: { discussed += 1 })

        try sut.inspect().find(button: "Discuss in Chat").tap()
        try sut.inspect().find(button: "Done").tap()

        XCTAssertEqual(discussed, 1)
        XCTAssertEqual(done, 1)
    }

    func testAddAndRegenerateOnlyOnToday() async throws {
        try await insertPlan(date: Self.today)
        try await insertPlan(date: Self.yesterday)

        let todayCard = try await pane(date: Self.today)
        XCTAssertNoThrow(try todayCard.inspect().find(viewWithAccessibilityLabel: "Add to the plan"))
        XCTAssertNoThrow(try todayCard.inspect().find(button: "Regenerate with feedback…"))

        let pastCard = try await pane(date: Self.yesterday)
        XCTAssertNoThrow(try pastCard.inspect().find(text: "Standup"), "a past card still lists its plan")
        XCTAssertThrowsError(try pastCard.inspect().find(viewWithAccessibilityLabel: "Add to the plan"))
        XCTAssertThrowsError(try pastCard.inspect().find(button: "Regenerate with feedback…"))
    }

    /// OWNER-02: without an owner today's card offers no Regenerate (the
    /// `day-plan` CLI needs one); adding an item is local and stays.
    func testRegenerateNeedsAnOwner() async throws {
        try await insertPlan(date: Self.today)
        let sut = try await pane(date: Self.today, owner: .unknown)

        XCTAssertThrowsError(try sut.inspect().find(button: "Regenerate with feedback…"))
        XCTAssertNoThrow(try sut.inspect().find(viewWithAccessibilityLabel: "Add to the plan"))
    }

    func testRegenerateIsAnInlineRow() async throws {
        try await insertPlan(date: Self.today)
        await plan.loadFor(date: Self.today)
        var row: InboxDayPlanRow?
        let binding = Binding(get: { row }, set: { row = $0 })

        try block(row: binding).inspect().find(button: "Regenerate with feedback…").tap()
        XCTAssertEqual(row, .regenerate)

        let open = block(row: binding)
        let field = try open.inspect().find(ViewType.TextField.self)
        XCTAssertEqual(try field.labelView().text().string(), "What should change?")
        XCTAssertTrue(try field.textFieldStyle() is KitFieldStyle)
        XCTAssertNoThrow(try open.inspect().find(button: "Regenerate"))
        XCTAssertThrowsError(try open.inspect().find(button: "Regenerate with feedback…"), "the row replaces its button")

        try open.inspect().find(button: "Cancel").tap()
        XCTAssertNil(row)
    }

    func testRegenerateShowsTheCLIRefusal() async throws {
        let refusal = "Morning brief is running now — try again in a minute"
        cli.shouldThrow = CLIRunnerError.nonZeroExit(code: 1, stderr: refusal)
        try await insertPlan(date: Self.today)
        await plan.loadFor(date: Self.today)
        var row: InboxDayPlanRow? = .regenerate
        let binding = Binding(get: { row }, set: { row = $0 })
        plan.feedbackDraft = "Move the standup after lunch"

        await block(row: binding).submitRegenerate()

        XCTAssertEqual(cli.invocations.last, ["day-plan", "generate", "--feedback", "Move the standup after lunch",
                                              "--date", Self.today])
        XCTAssertEqual(row, .regenerate, "the row stays open")
        XCTAssertEqual(plan.feedbackDraft, "Move the standup after lunch", "the draft is kept")
        let shown = block(row: binding)
        XCTAssertEqual(try shown.inspect().find(ViewType.TextField.self).input(), "Move the standup after lunch")
        XCTAssertTrue(try texts(shown).contains { $0.contains(refusal) }, "the CLI's stderr is shown in the row")
    }

    func testRegenerateSuccessClosesTheRow() async throws {
        try await insertPlan(date: Self.today)
        await plan.loadFor(date: Self.today)
        var row: InboxDayPlanRow? = .regenerate
        let binding = Binding(get: { row }, set: { row = $0 })
        plan.feedbackDraft = "Fewer meetings"

        await block(row: binding).submitRegenerate()

        XCTAssertNil(row)
        XCTAssertEqual(plan.feedbackDraft, "")
    }

    func testAddIsAnInlineRow() async throws {
        try await insertPlan(date: Self.today)
        await plan.loadFor(date: Self.today)
        var row: InboxDayPlanRow?
        let binding = Binding(get: { row }, set: { row = $0 })

        try block(row: binding).inspect().find(viewWithAccessibilityLabel: "Add to the plan").button().tap()
        XCTAssertEqual(row, .add)

        let open = block(row: binding)
        let field = try open.inspect().find(ViewType.TextField.self)
        XCTAssertEqual(try field.labelView().text().string(), "What needs to be done?")
        XCTAssertTrue(try field.textFieldStyle() is KitFieldStyle)
        XCTAssertNoThrow(try open.inspect().find(ViewType.Picker.self))
        XCTAssertEqual(try open.inspect().findAll(ViewType.DatePicker.self).count, 2, "a time block's start and end")
        XCTAssertNoThrow(try open.inspect().find(button: "Add"))

        try open.inspect().find(button: "Cancel").tap()
        XCTAssertNil(row)
    }

    func testConflictBannerShowsWhenThePlanHasConflicts() async throws {
        try await insertPlan(date: Self.today, hasConflicts: true)
        let sut = try await pane(date: Self.today)

        XCTAssertNoThrow(try sut.inspect().find(DayPlanConflictBanner.self))
        XCTAssertNoThrow(try sut.inspect().find(text: "Standup overlaps the design review"))

        try await insertPlan(date: Self.yesterday)
        let calm = try await pane(date: Self.yesterday)
        XCTAssertThrowsError(try calm.inspect().find(DayPlanConflictBanner.self))
    }

    /// A past day with only its briefing, or today's without an owner to
    /// make a plan: the brief alone, no plan header.
    func testBriefingOnlyCard() async throws {
        try await insertBriefing(date: Self.yesterday)
        let past = try await pane(date: Self.yesterday)
        XCTAssertNoThrow(try past.inspect().find(text: "Needs you"))
        XCTAssertThrowsError(try past.inspect().find(text: "Plan"))
        XCTAssertThrowsError(try past.inspect().find(viewWithAccessibilityLabel: "Add to the plan"))

        try await insertBriefing(date: Self.today)
        let noOwner = try await pane(date: Self.today, owner: .unknown)
        XCTAssertNoThrow(try noOwner.inspect().find(text: "Needs you"))
        XCTAssertThrowsError(try noOwner.inspect().find(text: "Plan"))
    }

    /// G4: with the Day Plan screen gone, today's card without a plan still
    /// makes one — above the brief, with no Add or Regenerate until it exists.
    func testTodayWithoutAPlanOffersMakeTodaysPlan() async throws {
        try await insertBriefing(date: Self.today)
        let sut = try await pane(date: Self.today)

        XCTAssertNoThrow(try sut.inspect().find(button: "Make today's plan"))
        XCTAssertNoThrow(try sut.inspect().find(text: "Needs you"))
        XCTAssertThrowsError(try sut.inspect().find(viewWithAccessibilityLabel: "Add to the plan"))
        XCTAssertThrowsError(try sut.inspect().find(button: "Regenerate with feedback…"))
    }

    func testMakeTodaysPlanShowsTheCLIRefusal() async throws {
        let refusal = "Morning brief is running now — try again in a minute"
        cli.shouldThrow = CLIRunnerError.nonZeroExit(code: 1, stderr: refusal)
        await plan.loadFor(date: Self.today)
        var row: InboxDayPlanRow?
        let binding = Binding(get: { row }, set: { row = $0 })

        await block(row: binding).submitGenerate()

        XCTAssertEqual(cli.invocations, [["day-plan", "generate", "--date", Self.today]])
        let shown = block(row: binding)
        XCTAssertTrue(try texts(shown).contains { $0.contains(refusal) }, "the CLI's stderr is shown on the card")
        XCTAssertNoThrow(try shown.inspect().find(button: "Make today's plan"), "the owner can try again")
    }

    /// G4: the Day Plan screen's Reset plan, as an inline confirm row.
    func testResetIsAnInlineConfirmRow() async throws {
        try await insertPlan(date: Self.today)
        await plan.loadFor(date: Self.today)
        var row: InboxDayPlanRow?
        let binding = Binding(get: { row }, set: { row = $0 })

        try block(row: binding).inspect().find(button: "Reset plan…").tap()
        XCTAssertEqual(row, .reset)
        let open = block(row: binding)
        XCTAssertNoThrow(try open.inspect().find(
            text: "Reset — today's plan is deleted, with the items you added. Your targets are not touched."
        ))
        XCTAssertNoThrow(try open.inspect().find(button: "Cancel"))
        XCTAssertNoThrow(try open.inspect().find(button: "Reset"))

        cli.shouldThrow = CLIRunnerError.nonZeroExit(code: 1, stderr: "database is locked")
        await open.submitReset()
        XCTAssertEqual(row, .reset, "a refusal keeps the row")
        XCTAssertTrue(try texts(block(row: binding)).contains { $0.contains("database is locked") })

        cli.shouldThrow = nil
        await block(row: binding).submitReset()
        XCTAssertEqual(cli.invocations.last, ["day-plan", "reset", Self.today])
        XCTAssertNil(row)
    }

    /// Switching cards fast: two loads of the shared view model overlap and
    /// the later one wins; its plan and items always belong together, and
    /// the earlier day's card shows no plan meanwhile.
    func testFastSwitchingNeverMixesDays() async throws {
        try await pool.write { db in
            for date in [Self.yesterday, Self.today] {
                let planID = try TestDatabase.insertDayPlan(db, planDate: date)
                try TestDatabase.insertDayPlanItem(db, dayPlanID: planID, kind: "backlog", title: "Item of \(date)")
            }
        }
        let first = Task { await plan.loadFor(date: Self.yesterday) }
        let second = Task { await plan.loadFor(date: Self.today) }
        await first.value
        await second.value

        XCTAssertEqual(plan.loadedDate, Self.today)
        XCTAssertEqual(plan.plan?.planDate, Self.today)
        XCTAssertEqual(plan.items.map(\.title), ["Item of \(Self.today)"])
        XCTAssertTrue(plan.items.allSatisfy { $0.dayPlanId == plan.plan?.id })

        let yesterdayCard = InboxDayCard(date: Self.yesterday, briefing: nil, plan: nil, planDone: 0, planTotal: 1, stamp: Date())
        let sut = InboxDayPane(card: yesterdayCard, today: Self.today, plan: plan, owner: Self.owner,
                               onDone: {}, onCommand: { _ in }, onOpenSource: { _ in })
        XCTAssertThrowsError(try sut.inspect().find(text: "Item of \(Self.today)"), "today's items never show on yesterday's card")
    }

    func testAddRowTakesTheTimesOnThePlansDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let late = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 23, minute: 0)))
        let later = late.addingTimeInterval(30 * 60)

        let range = try XCTUnwrap(InboxDayPlanAddRow.timeRange(on: Self.today, start: late, end: later, calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: range.0),
                       DateComponents(year: 2026, month: 10, day: 22, hour: 23, minute: 0))
        XCTAssertEqual(calendar.dateComponents([.day, .hour, .minute], from: range.1),
                       DateComponents(day: 22, hour: 23, minute: 30))
        XCTAssertNil(InboxDayPlanAddRow.timeRange(on: Self.today, start: later, end: late, calendar: calendar),
                     "an end before the start is refused")
        XCTAssertNil(InboxDayPlanAddRow.timeRange(on: Self.today, start: late, end: late, calendar: calendar))
    }

    func testPlanOnlyCard() async throws {
        try await insertPlan(date: Self.today)
        let sut = try await pane(date: Self.today)

        XCTAssertNoThrow(try sut.inspect().find(text: "Plan"))
        XCTAssertNoThrow(try sut.inspect().find(text: "Write tests"))
        for header in ["Needs you", "What happened", "Team pulse", "Coaching"] {
            XCTAssertThrowsError(try sut.inspect().find(text: header), header)
        }
        XCTAssertEqual(try texts(sut).filter { $0 == "Your day" }.count, 1, "the card's title, no briefing section")
    }

    func testBriefingItemOpensItsLink() throws {
        let briefing = try XCTUnwrap(try pool.write { db -> Briefing? in
            try TestDatabase.insertBriefing(db, date: Self.today, attention: Self.attention)
            return try BriefingQueries.fetchByDate(db, date: Self.today)
        })
        var opened: [BriefingLink] = []
        // Two closure parameters: a trailing closure would read as onMakeTask.
        // swiftlint:disable:next trailing_closure
        let sut = BriefingSectionsView(briefing: briefing, onOpen: { opened.append($0) })

        try sut.inspect().find(button: "Reply to the release thread").tap()

        XCTAssertEqual(opened, [.track(3)])
    }
}

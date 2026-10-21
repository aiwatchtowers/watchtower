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

    func testBriefingOnlyCard() async throws {
        try await insertBriefing(date: Self.today)
        let sut = try await pane(date: Self.today)

        XCTAssertNoThrow(try sut.inspect().find(text: "Needs you"))
        XCTAssertThrowsError(try sut.inspect().find(text: "Plan"))
        XCTAssertThrowsError(try sut.inspect().find(viewWithAccessibilityLabel: "Add to the plan"))
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

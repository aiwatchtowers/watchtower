import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The Inbox's Morning brief (spec "One brief row", §6.3, R10): the
/// mockup's order under a pane header with the day stepper and History;
/// Add and Regenerate with feedback… only on today's card, both inline rows.
@MainActor
final class InboxDayPaneTests: XCTestCase {
    nonisolated private static let today = "2026-10-22"
    nonisolated private static let yesterday = "2026-10-21"
    nonisolated private static let owner = Owner(
        id: "1:U1", source: .slack, slackUserID: "1:U1", email: "", jiraAccountID: "", displayName: "Me"
    )
    nonisolated private static let attention = #"[{"text":"Reply to the release thread","priority":"high","source_type":"track","source_id":"3"}]"#
    nonisolated private static let yourDay = #"[{"text":"Prepare the ACME-12 review"}]"#

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

    private func insertBriefing(date: String, yourDay: String = "[]") async throws {
        try await pool.write { db in
            try TestDatabase.insertBriefing(db, date: date, attention: Self.attention, yourDay: yourDay)
        }
    }

    /// Today's people and threads for the pane's `controls`.
    private func controls(onStep: @escaping (InboxBriefDays.Step) -> Void = { _ in }) -> InboxBriefControls {
        let item = InboxItem(row: Row(["id": 9, "snippet": "Will you approve the budget?"]
            as [String: (any DatabaseValueConvertible)?]))
        let track = Track(row: Row(["id": 4, "text": "The tag goes out Thursday"]
            as [String: (any DatabaseValueConvertible)?]))
        var controls = InboxBriefControls()
        controls.canStepOlder = true
        controls.onStep = onStep
        controls.waitingOnYou = [HomeFeedInboxRow(item: item, stamp: Date(), who: "Colleague B", whereText: nil)]
        controls.movedOvernight = [InboxTrackCard(track: track, lastEventAt: Date(), newEventCount: 1)]
        controls.onAllWaiting = {}
        controls.onTrackMyThreads = {}
        return controls
    }

    /// The card over what the database holds for `date`, with the view model
    /// loaded for it (the pane's `.task` does this on screen).
    private func pane(
        date: String,
        owner: Owner = InboxDayPaneTests.owner,
        onCommand: @escaping (InboxCardCommand) -> Void = { _ in },
        briefingVM: BriefingViewModel? = nil,
        emptyState: EmptyStateContext = .neutral,
        onMade: @escaping () async -> Void = {}
    ) async throws -> InboxDayPane {
        let (briefing, dayPlan) = try await pool.read { db in
            (try BriefingQueries.fetchByDate(db, date: date), try DayPlanQueries.fetchByDate(db, date: date))
        }
        await plan.loadFor(date: date)
        let card = InboxDayCard(date: date, briefing: briefing, plan: dayPlan,
                                planDone: 0, planTotal: plan.items.count, stamp: Date())
        let ignoreSource: (DayPlanItem) -> Void = { _ in }
        var sut = InboxDayPane(card: card, today: Self.today, plan: plan, owner: owner,
                               onCommand: onCommand, onOpenSource: ignoreSource)
        sut.briefing = briefingVM
        sut.emptyState = emptyState
        sut.onMade = onMade
        return sut
    }

    /// AppState's briefing view model over the same fake CLI, so one
    /// `invocations` list shows the order of both commands.
    private func briefingVM() throws -> BriefingViewModel {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        return BriefingViewModel(dbManager: manager, cliRunner: cli)
    }

    /// The plan block as the pane shows it, with its open row in `row`.
    private func block(row: Binding<InboxDayPlanRow?>, isToday: Bool = true) -> InboxDayPlanBlock {
        InboxDayPlanBlock(plan: plan, isToday: isToday, owner: Self.owner, openRow: row) { _ in }
    }

    private func texts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
    }

    // MARK: - Tests

    /// The mockup's order: the lead and Start here, Your day (the plan,
    /// then the brief's day items), Waiting on you, Moved overnight.
    func testSectionOrderFollowsTheMockup() async throws {
        try await insertPlan(date: Self.today)
        try await insertBriefing(date: Self.today, yourDay: Self.yourDay)
        var sut = try await pane(date: Self.today)
        sut.controls = controls()

        let all = try texts(sut)
        let order = try ["Start here", "Your day", "Standup", "Prepare the ACME-12 review", "Waiting on you",
                         "Moved overnight"].map { try XCTUnwrap(all.firstIndex(of: $0), $0) }
        XCTAssertEqual(order, order.sorted(), "found in \(all)")
        XCTAssertEqual(all.filter { $0 == "Reply to the release thread" }.count, 1,
                       "the lead repeats Start here #1, so it is drawn once")
        XCTAssertFalse(all.contains("Needs you"))
        XCTAssertEqual(all.first, "Morning brief")
        XCTAssertNoThrow(try sut.inspect().find(button: "All in Waiting for me"))
        XCTAssertNoThrow(try sut.inspect().find(button: "Track my threads"))
    }

    func testHeaderStepperDisablesNewerOnToday() async throws {
        try await insertBriefing(date: Self.today)
        try await insertBriefing(date: Self.yesterday)
        var steps: [InboxBriefDays.Step] = []
        var todayCard = try await pane(date: Self.today)
        todayCard.controls = controls { steps.append($0) }

        let newer = try todayCard.inspect().find(viewWithAccessibilityIdentifier: "inbox.brief.newer").button()
        XCTAssertTrue(newer.isDisabled(), "› is disabled on today")
        let older = try todayCard.inspect().find(viewWithAccessibilityIdentifier: "inbox.brief.older").button()
        XCTAssertFalse(older.isDisabled())
        try older.tap()
        XCTAssertNoThrow(try todayCard.inspect().find(text: "Thu 22 Oct"), "the stepper's date")
        XCTAssertNoThrow(try todayCard.inspect().find(button: "History"))

        var pastCard = try await pane(date: Self.yesterday)
        pastCard.controls = controls { steps.append($0) }
        try pastCard.inspect().find(viewWithAccessibilityIdentifier: "inbox.brief.newer").button().tap()
        XCTAssertEqual(steps, [.older, .newer])

        var oldest = try await pane(date: Self.yesterday)
        oldest.controls.canStepOlder = false
        let olderOfOldest = try oldest.inspect().find(viewWithAccessibilityIdentifier: "inbox.brief.older").button()
        XCTAssertTrue(olderOfOldest.isDisabled(), "‹ is disabled with no older day")
    }

    func testHistoryListsUnreadMarked() throws {
        func day(_ date: String, readAt: String?) throws -> InboxDayCard {
            let briefing = try XCTUnwrap(try pool.write { db -> Briefing? in
                try TestDatabase.insertBriefing(db, date: date, readAt: readAt)
                return try BriefingQueries.fetchByDate(db, date: date)
            })
            return InboxDayCard(date: date, briefing: briefing, plan: nil, planDone: 0, planTotal: 0, stamp: Date())
        }
        let days = [try day(Self.today, readAt: nil), try day(Self.yesterday, readAt: "2026-10-21T09:00:00Z")]
        var picked: [String] = []
        let sut = InboxBriefHistoryList(days: days, shownDate: Self.today) { picked.append($0) }

        func marked(_ id: String) throws -> Int {
            try sut.inspect().findAll { try $0.accessibilityIdentifier() == id }.count
        }
        XCTAssertEqual(try marked("inbox.brief.history.unread"), 1)
        XCTAssertEqual(try marked("inbox.brief.history.read"), 1)
        XCTAssertEqual(try texts(sut), ["Thu 22 Oct", "Wed 21 Oct"], "newest first, the stepper's date label")
        try sut.inspect().find(button: "Wed 21 Oct").tap()
        XCTAssertEqual(picked, [Self.yesterday])
    }

    /// Waiting on you and Moved overnight are today's: a past brief leaves them out.
    func testPastDayHidesTodayOnlySections() async throws {
        try await insertBriefing(date: Self.yesterday)
        var past = try await pane(date: Self.yesterday)
        past.controls = controls()
        XCTAssertNoThrow(try past.inspect().find(text: "Start here"))
        XCTAssertThrowsError(try past.inspect().find(text: "Waiting on you"))
        XCTAssertThrowsError(try past.inspect().find(text: "Moved overnight"))

        try await insertBriefing(date: Self.today)
        var today = try await pane(date: Self.today)
        var empty = controls()
        empty.waitingOnYou = []
        empty.movedOvernight = []
        today.controls = empty
        XCTAssertThrowsError(try today.inspect().find(text: "Waiting on you"), "left out when empty")
        XCTAssertThrowsError(try today.inspect().find(text: "Moved overnight"), "left out when empty")
    }

    func testConflictsChip() async throws {
        try await insertPlan(date: Self.today, hasConflicts: true)
        let sut = try await pane(date: Self.today)
        XCTAssertNoThrow(try sut.inspect().find(text: "1 conflict"))

        try await insertPlan(date: Self.yesterday)
        let calm = try await pane(date: Self.yesterday)
        XCTAssertThrowsError(try calm.inspect().find(text: "1 conflict"))
    }

    func testSubtitleSaysTheDayAndWhenItWasWritten() throws {
        let card = InboxDayCard.placeholder(date: Self.today, stamp: Date())
        XCTAssertEqual(InboxDayPane.subtitle(card), "Thursday, 22 October", "before a briefing, the day alone")

        let briefing = try Briefing(row: Row([
            "id": 1, "user_id": "u", "date": Self.today, "role": "", "attention": "[]", "your_day": "[]",
            "what_happened": "[]", "team_pulse": "[]", "coaching": "[]", "model": "", "input_tokens": 0,
            "output_tokens": 0, "cost_usd": 0.0, "prompt_version": 1, "read_at": nil,
            "created_at": "2026-10-22T06:02:00Z"
        ] as [String: (any DatabaseValueConvertible)?]))
        let written = InboxDayCard(date: Self.today, briefing: briefing, plan: nil, planDone: 0, planTotal: 0,
                                   stamp: Date())
        XCTAssertEqual(InboxDayPane.subtitle(written, timeZone: try XCTUnwrap(TimeZone(identifier: "UTC"))),
                       "Thursday, 22 October · written 06:02")
        XCTAssertEqual(InboxDayPane.subtitle(written, timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))),
                       "Thursday, 22 October · written 15:02", "the write time in the local time zone")
    }

    /// The lead is the first attention item: Start here draws it, the lead
    /// paragraph does not repeat it.
    func testLeadRepeatingStartHereIsDrawnOnce() async throws {
        try await insertBriefing(date: Self.today)
        let sut = try await pane(date: Self.today)
        let briefing = try XCTUnwrap(sut.card.briefing)

        XCTAssertEqual(InboxBriefLayout.lead(briefing), "Reply to the release thread", "the row's preview keeps it")
        XCTAssertNil(InboxDayPane.shownLead(briefing))
        XCTAssertEqual(try texts(sut).filter { $0 == "Reply to the release thread" }.count, 1)
    }

    /// No attention items: the lead falls back to the first your-day item,
    /// which Your day draws; it is not drawn twice.
    func testLeadFromYourDayIsDrawnOnce() async throws {
        try await pool.write { db in
            try TestDatabase.insertBriefing(db, date: Self.today, yourDay: Self.yourDay)
        }
        let sut = try await pane(date: Self.today)
        let briefing = try XCTUnwrap(sut.card.briefing)

        XCTAssertEqual(InboxBriefLayout.lead(briefing), "Prepare the ACME-12 review")
        XCTAssertNil(InboxDayPane.shownLead(briefing))
        XCTAssertEqual(try texts(sut).filter { $0 == "Prepare the ACME-12 review" }.count, 1)
        XCTAssertThrowsError(try sut.inspect().find(text: "Start here"), "no attention items, no Start here")
    }

    func testHeaderButtons() async throws {
        try await insertPlan(date: Self.today)
        var commands: [InboxCardCommand] = []
        let sut = try await pane(date: Self.today) { commands.append($0) }

        try sut.inspect().find(button: "Discuss in Chat").tap()

        guard case .chat(let subject, _)? = commands.first, commands.count == 1 else {
            return XCTFail("Discuss in Chat emits one chat command, got \(commands)")
        }
        XCTAssertEqual(subject.selection, .day(Self.today))
        XCTAssertThrowsError(try sut.inspect().find(button: "Hand to Agent…"))
        XCTAssertThrowsError(try sut.inspect().find(button: "Open source"))
        XCTAssertThrowsError(try sut.inspect().find(button: "Done"),
                             "nothing pins a day card, so it has no Done (ask #607)")
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
        XCTAssertNoThrow(try past.inspect().find(text: "Start here"))
        XCTAssertThrowsError(try past.inspect().find(text: "Plan"))
        XCTAssertThrowsError(try past.inspect().find(viewWithAccessibilityLabel: "Add to the plan"))

        try await insertBriefing(date: Self.today)
        let noOwner = try await pane(date: Self.today, owner: .unknown)
        XCTAssertNoThrow(try noOwner.inspect().find(text: "Start here"))
        XCTAssertThrowsError(try noOwner.inspect().find(text: "Plan"))
    }

    /// G4: with the Day Plan screen gone, today's card without a plan still
    /// makes one — above the brief, with no Add or Regenerate until it exists.
    func testTodayWithoutAPlanOffersMakeTodaysPlan() async throws {
        try await insertBriefing(date: Self.today)
        let sut = try await pane(date: Self.today)

        XCTAssertNoThrow(try sut.inspect().find(button: "Make today's plan"))
        XCTAssertNoThrow(try sut.inspect().find(text: "Start here"))
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
                               onCommand: { _ in }, onOpenSource: { _ in })
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
        for header in ["Start here", "Needs you", "More for today", "What happened", "Team pulse", "Coaching"] {
            XCTAssertThrowsError(try sut.inspect().find(text: header), header)
        }
        XCTAssertEqual(try texts(sut).filter { $0 == "Your day" }.count, 1, "the plan's section, no briefing one")
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

    // MARK: - Make today's brief and plan (T11b, G4)

    /// Today with neither: when the brief comes, then one primary button; no
    /// plan block's own Make today's plan.
    func testTodayWithNothingOffersMakeBriefAndPlan() async throws {
        var context = EmptyStateContext.neutral
        context.readiness = { $0 == .briefing ? .preparing(detail: nil) : nil }
        context.briefingHour = 9
        let sut = try await pane(date: Self.today, briefingVM: try briefingVM(), emptyState: context)

        XCTAssertNoThrow(try sut.inspect().find(text: "Nothing is ready for today yet."))
        XCTAssertNoThrow(try sut.inspect().find(text: "Preparing now"), "the readiness line says when")
        XCTAssertTrue(try texts(sut).contains { $0.contains("09:00") }, "the brief's hour")
        XCTAssertNoThrow(try sut.inspect().find(button: "Make today's brief and plan"))
        XCTAssertThrowsError(try sut.inspect().find(button: "Make today's plan"))
        XCTAssertThrowsError(try sut.inspect().find(button: "Make today's brief"))
    }

    func testMakeBriefAndPlanRunsBothInOrderThenRefreshes() async throws {
        var made = 0
        let sut = try await pane(date: Self.today, briefingVM: try briefingVM()) { made += 1 }

        await sut.makeBriefAndPlan()

        XCTAssertEqual(cli.invocations, [["briefing", "generate"], ["day-plan", "generate", "--date", Self.today]])
        XCTAssertEqual(made, 1)
    }

    /// A refused brief stops before the plan; the refusal shows on the card.
    func testMakeBriefAndPlanShowsTheRefusal() async throws {
        let refusal = "no owner identity: connect Slack, Google or Jira first"
        cli.shouldThrow = CLIRunnerError.nonZeroExit(code: 1, stderr: refusal)
        let briefing = try briefingVM()
        let sut = try await pane(date: Self.today, briefingVM: briefing)

        await sut.makeBriefAndPlan()

        XCTAssertEqual(cli.invocations, [["briefing", "generate"]])
        XCTAssertTrue(try texts(sut).contains { $0.contains(refusal) }, "the CLI's stderr is shown inline")
        XCTAssertNoThrow(try sut.inspect().find(button: "Make today's brief and plan"), "the owner can try again")
    }

    /// OWNER-02: no owner, no Make button; the connect-an-identity message.
    func testNothingReadyWithoutAnOwnerShowsTheOwnerMessage() async throws {
        let sut = try await pane(date: Self.today, owner: .unknown, briefingVM: try briefingVM())

        XCTAssertNoThrow(try sut.inspect().find(button: "Open Connections"))
        XCTAssertThrowsError(try sut.inspect().find(button: "Make today's brief and plan"))
    }

    func testAPastDayNeverOffersToMakeIt() async throws {
        let sut = try await pane(date: Self.yesterday, briefingVM: try briefingVM())

        XCTAssertThrowsError(try sut.inspect().find(text: "Nothing is ready for today yet."))
        XCTAssertThrowsError(try sut.inspect().find(button: "Make today's brief and plan"))
    }

    /// Today's plan without a brief: a secondary Make today's brief.
    func testPlanOnlyTodayOffersMakeTodaysBrief() async throws {
        try await insertPlan(date: Self.today)
        var made = 0
        let sut = try await pane(date: Self.today, briefingVM: try briefingVM()) { made += 1 }

        XCTAssertNoThrow(try sut.inspect().find(button: "Make today's brief"))
        XCTAssertThrowsError(try sut.inspect().find(button: "Make today's brief and plan"))
        await sut.makeBrief()
        XCTAssertEqual(cli.invocations, [["briefing", "generate"]])
        XCTAssertEqual(made, 1)

        let past = try await pane(date: Self.yesterday, briefingVM: try briefingVM())
        XCTAssertThrowsError(try past.inspect().find(button: "Make today's brief"))
    }

    /// Today's brief without a plan keeps the plan block's Make today's plan.
    func testBriefOnlyTodayKeepsMakeTodaysPlan() async throws {
        try await insertBriefing(date: Self.today)
        let sut = try await pane(date: Self.today, briefingVM: try briefingVM())

        XCTAssertNoThrow(try sut.inspect().find(button: "Make today's plan"))
        XCTAssertThrowsError(try sut.inspect().find(button: "Make today's brief and plan"))
        XCTAssertThrowsError(try sut.inspect().find(button: "Make today's brief"))
    }

    /// An established install (day plan rows exist) with no plan for today
    /// yet gets a calm line, not the first-run screen (owner, ask #299).
    /// Ported from the Day Plan screen's empty state to today's empty card.
    func testDayPlanEstablishedWithoutTodaysPlanSaysWhen() async throws {
        let context = EmptyStateContext.neutral
        let firstRunTitle = try XCTUnwrap(EmptyStateCopyTable.copy(for: "dayPlan", briefingHour: 8)).title
        func view(_ owner: Owner, _ context: EmptyStateContext) async throws -> InboxDayPane {
            try await pane(date: Self.today, owner: owner, briefingVM: try briefingVM(), emptyState: context)
        }
        var established = context
        established.readiness = { _ in .ready }
        established.briefingHour = 8
        let sut = try await view(Self.owner, established)
        XCTAssertNoThrow(try sut.inspect().find(text: "Today's plan at or after 08:00"))
        XCTAssertThrowsError(try sut.inspect().find(text: firstRunTitle), "not the first-run screen")

        established.briefingHour = 10
        let later = try await view(Self.owner, established)
        XCTAssertNoThrow(try later.inspect().find(text: "Today's plan at or after 10:00"), "the briefing hour")

        // No owner: the daemon makes no plan, so no time is promised.
        let noOwner = try await view(.unknown, established)
        XCTAssertThrowsError(try noOwner.inspect().find(text: "Today's plan at or after 10:00"))
        XCTAssertNoThrow(try noOwner.inspect().find(button: "Open Connections"))

        // A fresh install keeps the first-run copy.
        let fresh = try await view(Self.owner, context)
        XCTAssertNoThrow(try fresh.inspect().find(text: firstRunTitle))
        XCTAssertThrowsError(try fresh.inspect().find(text: "Today's plan at or after 08:00"))
    }
}

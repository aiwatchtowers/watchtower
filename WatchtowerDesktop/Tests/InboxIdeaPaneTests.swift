import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Inbox's idea card and the Ideas filter's own actions (spec §6.3, R9,
/// ruling F15): the verdict buttons, Not now ▾, merge and delete as inline
/// rows, a decision's Supersede / Reverse, the New idea row and Find Ideas in
/// Past Messages….
@MainActor
final class InboxIdeaPaneTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var cli: FakeCLIRunner!
    private var ideas: IdeasViewModel!

    override func setUp() async throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        cli = FakeCLIRunner()
        ideas = IdeasViewModel(dbManager: dbManager, cliRunner: cli)
    }

    override func tearDown() async throws {
        ideas = nil
        cli = nil
        TestDatabase.cleanup(path: dbPath)
        dbManager = nil
    }

    // MARK: - Fixtures

    private func insert(
        kind: String = "idea",
        title: String = "Ship a weekly digest email",
        status: String = "proposed",
        needsReview: Bool = false,
        similarToID: Int? = nil
    ) throws -> Idea {
        try dbManager.dbPool.write { db in
            let id = try TestDatabase.insertIdea(db, kind: kind, title: title, status: status,
                                                 needsReview: needsReview, similarToID: similarToID)
            return try XCTUnwrap(IdeaQueries.fetchOne(db, id: Int(id)))
        }
    }

    private func stored(_ id: Int) throws -> Idea? {
        try dbManager.dbPool.read { db in try IdeaQueries.fetchOne(db, id: id) }
    }

    private func bar(
        _ idea: Idea,
        allIdeas: [Idea] = [],
        actions: IdeaActions = IdeaActions(),
        row: Binding<IdeaActionRow?> = .constant(nil)
    ) -> IdeaActionBar {
        IdeaActionBar(idea: idea, allIdeas: allIdeas, actions: actions, openRow: row)
    }

    /// The card over `ideas`, with each callback spelled out.
    private func pane(
        _ idea: Idea,
        allIdeas: [Idea] = [],
        onChange: @escaping () async -> Void = {},
        onMadeTask: @escaping (Int) -> Void = { _ in },
        onDeleted: @escaping (Int) -> Void = { _ in }
    ) -> InboxIdeaPane {
        InboxIdeaPane(idea: idea, ideas: ideas, allIdeas: allIdeas,
                      onChange: onChange, onMadeTask: onMadeTask, onDeleted: onDeleted)
    }

    private func buttons(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Button.self).compactMap { button in
            (try? button.labelView().text().string())
                ?? (try? button.labelView().label().title().text().string())
        }
    }

    private func texts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); return }
            await Task.yield()
        }
    }

    // MARK: - Verdict buttons

    func testVerdictButtons() throws {
        let proposed = try insert()
        let labels = try buttons(bar(proposed))
        for label in ["Approve", "Make a Task", "Reject", "Merge…"] {
            XCTAssertTrue(labels.contains(label), "\(label) in \(labels)")
        }
        XCTAssertFalse(labels.contains("Drop"))
        let menu = try bar(proposed).inspect().find(ViewType.Menu.self)
        XCTAssertEqual(try menu.labelView().text().string(), "Not now")
        for item in ["1 week", "1 month", "No date"] {
            XCTAssertNoThrow(try menu.find(button: item), item)
        }
        XCTAssertTrue(try bar(proposed).inspect().find(button: "Approve").buttonStyle() is KitPrimaryButtonStyle)

        // Brought up again after a Reject (IDEA-04): the same four, so the flag clears.
        let resurfaced = try insert(title: "Rejected, mentioned again", status: "rejected", needsReview: true)
        let again = try buttons(bar(resurfaced))
        XCTAssertTrue(again.contains("Approve") && again.contains("Reject") && again.contains("Make a Task"))

        // A note waiting for a verdict: no task, no snooze.
        let note = try insert(kind: "note", title: "Release notes live in the wiki")
        let noteLabels = try buttons(bar(note))
        XCTAssertTrue(noteLabels.contains("Approve") && noteLabels.contains("Reject"))
        XCTAssertFalse(noteLabels.contains("Make a Task"))
        XCTAssertThrowsError(try bar(note).inspect().find(ViewType.Menu.self))
    }

    func testDecidedIdeasKeepTheirLifecycleButtons() throws {
        let active = try buttons(bar(insert(title: "Active", status: "active")))
        XCTAssertTrue(active.contains("Make a Task") && active.contains("Drop"))
        XCTAssertFalse(active.contains("Approve") || active.contains("Reject"))

        let rejected = try buttons(bar(insert(title: "Rejected", status: "rejected")))
        XCTAssertTrue(rejected.contains("Activate"), "IDEA-04: a rejected idea can come back")
        XCTAssertTrue(rejected.contains("Merge…"))

        let converted = try buttons(bar(insert(title: "Converted", status: "converted")))
        XCTAssertFalse(converted.contains("Merge…"))
    }

    /// F15: a decision is informational — Supersede / Reverse, never a verdict.
    func testADecisionShowsSupersedeAndReverseOnly() async throws {
        let decision = try insert(kind: "decision", title: "Ship on Thursdays", status: "active")
        let labels = try buttons(bar(decision))
        XCTAssertTrue(labels.contains("Supersede") && labels.contains("Reverse"), "\(labels)")
        for absent in ["Approve", "Reject", "Make a Task", "Activate"] {
            XCTAssertFalse(labels.contains(absent), absent)
        }
        XCTAssertThrowsError(try bar(decision).inspect().find(ViewType.Menu.self))
        // Even proposed (the old birth status), a decision gets no verdict.
        let proposed = try insert(kind: "decision", title: "Old proposed decision", status: "proposed")
        XCTAssertFalse(try buttons(bar(proposed)).contains("Approve"))

        var changes = 0
        let card = pane(decision, onChange: { changes += 1 }, onMadeTask: { _ in }, onDeleted: { _ in })
        await card.actions.supersede()
        XCTAssertEqual(try stored(decision.id)?.status, .superseded)
        let other = try insert(kind: "decision", title: "Use the monorepo", status: "active")
        await pane(other).actions.reverse()
        XCTAssertEqual(try stored(other.id)?.status, .reversed)
        XCTAssertEqual(changes, 1)
    }

    /// G4: the decision card keeps what the Ideas screen's pane gave a
    /// decision — Merge, delete, and Activate out of a resurfaced verdict.
    func testADecisionKeepsMergeDeleteAndItsWayOut() async throws {
        let active = try insert(kind: "decision", title: "Ship on Thursdays", status: "active")
        let labels = try buttons(bar(active))
        XCTAssertTrue(labels.contains("Merge…"), "\(labels)")
        XCTAssertNoThrow(try bar(active).inspect().find(viewWithAccessibilityLabel: "Delete permanently"))

        // Brought up again after a Reject (IDEA-04 flags any kind): Activate clears it.
        let flagged = try insert(kind: "decision", title: "Freeze on Fridays", status: "rejected", needsReview: true)
        let flaggedLabels = try buttons(bar(flagged))
        XCTAssertTrue(flaggedLabels.contains("Activate") && flaggedLabels.contains("Merge…"), "\(flaggedLabels)")
        XCTAssertFalse(flaggedLabels.contains("Approve") || flaggedLabels.contains("Reject"), "never a verdict (F15)")
        await pane(flagged).actions.activate()
        let cleared = try XCTUnwrap(try stored(flagged.id))
        XCTAssertEqual(cleared.status, .active)
        XCTAssertFalse(cleared.needsReview)

        for status in ["not_now", "dropped"] {
            let parked = try insert(kind: "decision", title: "Parked \(status)", status: status, needsReview: true)
            XCTAssertTrue(try buttons(bar(parked)).contains("Activate"), status)
        }

        // Merge into another decision, and delete, both from the card.
        let target = try insert(kind: "decision", title: "Release weekly", status: "active")
        let mergeable = try insert(kind: "decision", title: "Release every week", status: "active")
        XCTAssertEqual(IdeaMergeRow.eligible([target, mergeable, active], for: mergeable, preselect: nil).map(\.id),
                       [target.id, active.id])
        await pane(mergeable).actions.merge(target.id)
        XCTAssertEqual(try stored(mergeable.id)?.status, .merged)
        await pane(active).actions.delete()
        XCTAssertNil(try stored(active.id))
    }

    /// M7: a press while the card's write is pending writes nothing more,
    /// and the bar's buttons wait.
    func testAPressWhileAWriteIsPendingDoesNothing() async throws {
        let idea = try insert()
        XCTAssertTrue(try bar(idea).inspect().find(button: "Approve").isDisabled() == false)
        var writing = bar(idea)
        writing.isWriting = true
        XCTAssertTrue(try writing.inspect().find(button: "Approve").isDisabled())
        XCTAssertTrue(try writing.inspect().find(viewWithAccessibilityLabel: "Delete permanently").isDisabled())

        var changes = 0
        let card = pane(idea, onChange: { changes += 1 }, onMadeTask: { _ in }, onDeleted: { _ in })
        await ideas.pendingWrites.run(InboxIdeaPane.writeKey(idea.id)) {
            await card.actions.reject()
        }
        XCTAssertEqual(try stored(idea.id)?.status, .proposed, "the second press did not write")
        XCTAssertEqual(changes, 0)
        await card.actions.reject()
        XCTAssertEqual(try stored(idea.id)?.status, .rejected)
        XCTAssertEqual(changes, 1)
    }

    /// M5: while the New idea row's Create is on screen, Approve is not prominent too.
    func testApproveStepsBackWhileTheNewIdeaRowIsOpen() throws {
        let idea = try insert()
        var quiet = bar(idea)
        quiet.approveIsPrimary = false
        XCTAssertTrue(try quiet.inspect().find(button: "Approve").buttonStyle() is KitSecondaryButtonStyle)
    }

    func testTheIdeaPaneShowsTheBarInTheDetailPane() throws {
        let idea = try insert()
        let sut = InboxIdeaPane(idea: idea, ideas: ideas, allIdeas: []).environment(AppState.isolated())
        XCTAssertNoThrow(try sut.inspect().find(button: "Approve"))
        XCTAssertNoThrow(try sut.inspect().find(text: idea.title))
    }

    func testApproveAndRejectWriteTheVerdictAndReRead() async throws {
        let first = try insert(title: "First")
        let second = try insert(title: "Second", status: "rejected", needsReview: true)
        var changes = 0
        await pane(first, onChange: { changes += 1 }, onMadeTask: { _ in }, onDeleted: { _ in }).actions.approve()
        await pane(second, onChange: { changes += 1 }, onMadeTask: { _ in }, onDeleted: { _ in }).actions.reject()

        XCTAssertEqual(try stored(first.id)?.status, .active)
        let rejected = try XCTUnwrap(try stored(second.id))
        XCTAssertEqual(rejected.status, .rejected)
        XCTAssertFalse(rejected.needsReview, "the verdict clears the resurfacing flag (IDEA-04)")
        XCTAssertEqual(changes, 2, "the Inbox re-reads after each write")
    }

    func testMakeATaskConvertsAndOpensTheTarget() async throws {
        let idea = try insert(status: "active")
        var opened: [Int] = []
        await pane(idea, onChange: {}, onMadeTask: { opened.append($0) }, onDeleted: { _ in }).actions.makeTask()
        let converted = try XCTUnwrap(try stored(idea.id))
        XCTAssertEqual(converted.status, .converted)
        XCTAssertEqual(opened, [try XCTUnwrap(converted.convertedTargetID)])
    }

    // MARK: - Not now

    func testNotNowOneWeekSnoozesSevenDays() async throws {
        // The owner-local day: 23:30 UTC is already the next day at +02:00.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 2 * 3600))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-22T23:30:00Z"))
        XCTAssertEqual(IdeaNotNow.week.until(now: now, calendar: calendar), "2026-10-30")
        XCTAssertEqual(IdeaNotNow.month.until(now: now, calendar: calendar), "2026-11-23")
        XCTAssertEqual(IdeaNotNow.noDate.until(now: now, calendar: calendar), "")

        // The menu passes today + 7 in the owner's calendar.
        let idea = try insert()
        let sent = expectation(description: "not now")
        var until: String?
        var actions = IdeaActions()
        actions.notNow = { value in
            until = value
            sent.fulfill()
        }
        try bar(idea, actions: actions).inspect().find(ViewType.Menu.self).find(button: "1 week").tap()
        await fulfillment(of: [sent], timeout: 5)
        let week = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 7, to: Date()))
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: week)
        let expected = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        XCTAssertEqual(until, expected)

        // And the card writes it.
        await pane(idea).actions.notNow(expected)
        let snoozed = try XCTUnwrap(try stored(idea.id))
        XCTAssertEqual(snoozed.status, .notNow)
        XCTAssertEqual(snoozed.snoozeUntil, expected)
    }

    // MARK: - Merge and delete, inline

    func testMergeIsInline() async throws {
        let hint = try insert(title: "Weekly digest by email", status: "active")
        let idea = try insert(title: "Ship a weekly digest", similarToID: hint.id)
        let other = try insert(title: "Dark mode", status: "proposed")
        let note = try insert(kind: "note", title: "A note", status: "active")
        let closed = try insert(title: "Old rejected", status: "rejected")
        let all = [idea, other, note, closed, hint]

        var row: IdeaActionRow?
        let binding = Binding(get: { row }, set: { row = $0 })
        try bar(idea, allIdeas: all, row: binding).inspect().find(button: "Merge…").tap()
        XCTAssertEqual(row, .merge(preselect: hint.id))

        let merged = expectation(description: "merge")
        var into: Int?
        var actions = IdeaActions()
        actions.merge = { id in
            into = id
            merged.fulfill()
        }
        let open = bar(idea, allIdeas: all, actions: actions, row: binding)
        XCTAssertNoThrow(try open.inspect().find(IdeaMergeRow.self))
        XCTAssertNoThrow(try open.inspect().find(text: "Merge this idea into…"))
        XCTAssertNoThrow(try open.inspect().find(text: "Similar"))
        // Same kind, still open, never itself; the hint first.
        XCTAssertEqual(IdeaMergeRow.eligible(all, for: idea, preselect: hint.id).map(\.id), [hint.id, other.id])
        try open.inspect().find(IdeaMergeRow.self).find(button: "Merge").tap()
        await fulfillment(of: [merged], timeout: 5)
        XCTAssertEqual(into, hint.id)

        try open.inspect().find(button: "Cancel").tap()
        XCTAssertNil(row)

        await pane(idea, allIdeas: all).actions.merge(hint.id)
        XCTAssertEqual(try stored(idea.id)?.status, .merged)
    }

    /// Reverse asks first, inline; only the row's **Reverse** reverses.
    func testReverseAsksInline() async throws {
        let decision = try insert(kind: "decision", title: "Ship on Thursdays", status: "active")
        var row: IdeaActionRow?
        let binding = Binding(get: { row }, set: { row = $0 })
        var reversed = 0
        var actions = IdeaActions()
        let done = expectation(description: "reverse")
        actions.reverse = {
            reversed += 1
            done.fulfill()
        }
        try bar(decision, actions: actions, row: binding).inspect().find(button: "Reverse").tap()
        XCTAssertEqual(row, .reverse)
        XCTAssertEqual(reversed, 0, "the first press only asks")

        let open = bar(decision, actions: actions, row: binding)
        XCTAssertNoThrow(try open.inspect().find(text: "Reverse this decision?"))
        try open.inspect().find(IdeaReverseRow.self).find(button: "Cancel").tap()
        XCTAssertNil(row)
        row = .reverse
        let confirm = try bar(decision, actions: actions, row: binding).inspect().find(IdeaReverseRow.self)
        try confirm.find(button: "Reverse").tap()
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(reversed, 1)
        XCTAssertNil(row)
    }

    func testDeleteIsInline() async throws {
        let idea = try insert()
        var row: IdeaActionRow?
        let binding = Binding(get: { row }, set: { row = $0 })
        try bar(idea, row: binding).inspect().find(viewWithAccessibilityLabel: "Delete permanently").button().tap()
        XCTAssertEqual(row, .delete)

        let deleted = expectation(description: "delete")
        var actions = IdeaActions()
        actions.delete = { deleted.fulfill() }
        let open = bar(idea, actions: actions, row: binding)
        XCTAssertNoThrow(try open.inspect().find(text: "Delete this idea?"))
        try open.inspect().find(IdeaDeleteRow.self).find(button: "Delete").tap()
        await fulfillment(of: [deleted], timeout: 5)
        try open.inspect().find(IdeaDeleteRow.self).find(button: "Cancel").tap()
        XCTAssertNil(row)

        var gone: [Int] = []
        await pane(idea, onChange: {}, onMadeTask: { _ in }, onDeleted: { gone.append($0) }).actions.delete()
        XCTAssertNil(try stored(idea.id))
        XCTAssertEqual(gone, [idea.id])
    }

    // MARK: - New idea and Find Ideas

    func testNewIdeaRowCreatesAManualIdea() async throws {
        var draft = InboxNewIdeaDraft(kind: .idea, title: "Offer a CSV export", essence: "Teams ask for it weekly.")
        let binding = Binding(get: { draft }, set: { draft = $0 })
        var created: [Int] = []
        let row = InboxNewIdeaRow(ideas: ideas, draft: binding, onCreated: { created.append($0) }, onCancel: {})

        let create = try row.inspect().find(button: "Create")
        XCTAssertEqual(InboxNewIdeaRow.createShortcut, KeyboardShortcut(.return, modifiers: .command))
        XCTAssertFalse(create.isDisabled())

        await row.create()

        let id = try XCTUnwrap(created.first)
        let idea = try XCTUnwrap(try stored(id))
        XCTAssertEqual(idea.kind, .idea)
        XCTAssertEqual(idea.title, "Offer a CSV export")
        XCTAssertEqual(idea.status, .active)
        XCTAssertEqual(idea.source, "owner")
        XCTAssertEqual(draft, InboxNewIdeaDraft(), "the draft clears once the idea exists")

        // M6: a failed create says why once, in the row, not again in the card's banner.
        draft = InboxNewIdeaDraft(title: "Another idea")
        try await dbManager.dbPool.write { db in try db.execute(sql: "DROP TABLE ideas") }
        await row.create()
        XCTAssertEqual(created.count, 1, "nothing created")
        XCTAssertNil(ideas.errorMessage, "the row took the error")
        XCTAssertEqual(draft.title, "Another idea", "the draft is kept")

        draft = InboxNewIdeaDraft(title: "   ")
        XCTAssertTrue(try row.inspect().find(button: "Create").isDisabled(), "a blank title creates nothing")
    }

    func testBackfillRowStartsTheRange() async throws {
        let from = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-01T12:00:00Z"))
        let to = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-15T12:00:00Z"))
        var range = InboxIdeaBackfillRange(from: from, to: to)
        let row = InboxIdeaBackfillRow(ideas: ideas, range: Binding(get: { range }, set: { range = $0 })) {}

        try row.inspect().find(button: "Find Ideas").tap()

        XCTAssertEqual(ideas.backfillFrom, from)
        XCTAssertEqual(ideas.backfillTo, to)
        await waitUntil("the mining run to reach the CLI") { !cli.invocations.isEmpty }
        let args = try XCTUnwrap(cli.invocations.first)
        XCTAssertEqual(Array(args.prefix(2)), ["ideas", "mine"])
        XCTAssertTrue(args.contains("--from") && args.contains("--to"))
        await waitUntil("the run to end") { !ideas.isBackfilling }

        // Reopened, the row starts from the range that ran.
        XCTAssertEqual(InboxIdeaBackfillRange.initial(ideas), InboxIdeaBackfillRange(from: from, to: to))
    }

    func testTheIdeasFilterHeaderOffersNewIdeaAndFindIdeas() throws {
        var row: InboxIdeasRow?
        let header = InboxIdeasHeader(isMining: false, row: Binding(get: { row }, set: { row = $0 }))
        try header.inspect().find(viewWithAccessibilityLabel: "New Idea").button().tap()
        XCTAssertEqual(row, .newIdea)

        var found = 0
        let onIdeas = InboxFilterBar(filter: .constant(.ideas), showsCheatSheetButton: true, onOpenAux: { _ in },
                                     onFindIdeas: { found += 1 }, ideasHeader: { header })
        try onIdeas.inspect().find(button: "Find Ideas in Past Messages…").tap()
        XCTAssertEqual(found, 1)
        XCTAssertNoThrow(try onIdeas.inspect().find(viewWithAccessibilityLabel: "New Idea"))

        let onAll = InboxFilterBar(filter: .constant(.all), showsCheatSheetButton: true, onOpenAux: { _ in },
                                   onFindIdeas: { found += 1 }, ideasHeader: { header })
        XCTAssertThrowsError(try onAll.inspect().find(button: "Find Ideas in Past Messages…"))
        XCTAssertThrowsError(try onAll.inspect().find(viewWithAccessibilityLabel: "New Idea"))
    }
}

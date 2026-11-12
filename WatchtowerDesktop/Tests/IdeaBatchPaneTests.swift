import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Idea finder's one-card pane and its verdict dispatch (spec "Idea finder
/// (phase 3)"): Keep → active, Drop → rejected, Later → not_now with no
/// date, Make a Target… → a converted idea; one verdict per idea at a time.
@MainActor
final class IdeaBatchPaneTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var ideas: IdeasViewModel!

    override func setUp() async throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        ideas = IdeasViewModel(dbManager: dbManager)
    }

    override func tearDown() async throws {
        ideas = nil
        TestDatabase.cleanup(path: dbPath)
        dbManager = nil
    }

    // MARK: - Fixtures

    private func insert(
        title: String = "One release checklist for every team",
        essence: String = "",
        status: String = "proposed",
        needsReview: Bool = false
    ) throws -> Idea {
        try dbManager.dbPool.write { db in
            let id = try TestDatabase.insertIdea(db, title: title, essence: essence, status: status,
                                                 needsReview: needsReview)
            return try XCTUnwrap(IdeaQueries.fetchOne(db, id: Int(id)))
        }
    }

    private func stored(_ id: Int) throws -> Idea {
        try XCTUnwrap(try dbManager.dbPool.read { db in try IdeaQueries.fetchOne(db, id: id) })
    }

    private func state(
        batchIDs: [Int],
        remaining: [Idea],
        keptToday: [Idea] = [],
        backlogCount: Int = 0,
        nextAvailable: Int = 0,
        size: Int = 13
    ) -> IdeaBatchState {
        // The memberwise init is internal to WatchtowerCore: start from an
        // empty state and set the parts under test.
        var state = IdeaDailyBatch.state(ideas: [], batchIDs: [], now: Date(), size: size, calendar: .current)
        state.batchIDs = batchIDs
        state.remaining = remaining
        state.keptToday = keptToday
        state.backlogCount = backlogCount
        state.nextAvailable = nextAvailable
        return state
    }

    private func pane(_ state: IdeaBatchState, isWriting: Bool = false, errorMessage: String? = nil) -> IdeaBatchPane {
        IdeaBatchPane(state: state, isWriting: isWriting, errorMessage: errorMessage,
                      loadFacts: { _ in nil }, onPress: { _, _ in }, onNext: {}, onBacklog: {},
                      onDismissError: {})
    }

    private func texts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
    }

    // MARK: - Dispatch

    func testKeepWritesActive() async throws {
        let idea = try insert()
        let result = await ideas.press(.keep, on: idea)
        XCTAssertEqual(result, idea.id)
        XCTAssertEqual(try stored(idea.id).status, .active)
    }

    func testDropWritesRejectedNotDropped() async throws {
        let idea = try insert()
        let result = await ideas.press(.drop, on: idea)
        XCTAssertEqual(result, idea.id)
        XCTAssertEqual(try stored(idea.id).status, .rejected)
    }

    func testLaterWritesNotNowWithoutDate() async throws {
        let idea = try insert()
        let result = await ideas.press(.later, on: idea)
        XCTAssertEqual(result, idea.id)
        let after = try stored(idea.id)
        XCTAssertEqual(after.status, .notNow)
        XCTAssertEqual(after.snoozeUntil, "")
    }

    func testMakeTargetConvertsAndReturnsTheTarget() async throws {
        let idea = try insert()
        let pressed = await ideas.press(.makeTarget, on: idea)
        let targetID = try XCTUnwrap(pressed)
        let after = try stored(idea.id)
        XCTAssertEqual(after.status, .converted)
        XCTAssertEqual(after.convertedTargetID, targetID)
    }

    /// Every press is the owner looking at the idea: a resurfaced one leaves
    /// the review queue (IDEA-04).
    func testEachPressClearsNeedsReview() async throws {
        for press in IdeaBatchPress.allCases {
            let idea = try insert(title: "Resurfaced \(press.title)", status: "rejected", needsReview: true)
            let pressed = await ideas.press(press, on: idea)
            XCTAssertNotNil(pressed, press.title)
            let after = try stored(idea.id)
            XCTAssertFalse(after.needsReview, press.title)
            XCTAssertFalse(after.awaitsVerdict, press.title)
        }
    }

    func testPressWhilePendingIsIgnored() async throws {
        let idea = try insert()
        // Two concurrent presses on one idea (K then D): one write.
        async let first = ideas.press(.keep, on: idea)
        async let second = ideas.press(.drop, on: idea)
        let results = await [first, second]
        XCTAssertEqual(results.compactMap { $0 }, [idea.id])
        XCTAssertEqual(try stored(idea.id).status, .active)

        // A press while the card's verdict key is held does nothing.
        let other = try insert(title: "Another idea")
        let nested = await ideas.pendingWrites.run(InboxIdeaPane.writeKey(other.id)) {
            await ideas.press(.drop, on: other)
        }
        XCTAssertEqual(nested, .some(nil))
        XCTAssertEqual(try stored(other.id).status, .proposed)
    }

    func testFailedPressReturnsNilWithError() async throws {
        let idea = try insert()
        try await dbManager.dbPool.write { db in try db.execute(sql: "DELETE FROM ideas WHERE id = ?", arguments: [idea.id]) }
        let pressed = await ideas.press(.keep, on: idea)
        XCTAssertNil(pressed)
        XCTAssertNotNil(ideas.errorMessage)
    }

    // MARK: - Press gate

    /// The card that was pressed takes no second press until another card is
    /// shown (or its write failed): K K, or K then D, before the batch
    /// re-reads, writes one verdict.
    func testGateAdmitsOnePressPerShownCard() {
        var gate = IdeaBatchPressGate()
        XCTAssertTrue(gate.admit(1, isWriting: false))
        XCTAssertFalse(gate.admit(1, isWriting: false))
        XCTAssertFalse(gate.admit(2, isWriting: true))
        XCTAssertTrue(gate.admit(2, isWriting: false))
        gate.release()
        XCTAssertTrue(gate.admit(2, isWriting: false))
    }

    // MARK: - View

    func testShowsFirstRemainingWithFourButtonsKeepProminent() throws {
        let first = try insert(title: "One release checklist for every team",
                               essence: "Three teams keep their own checklist.")
        let second = try insert(title: "Automate the weekly QA status mail")
        let view = pane(state(batchIDs: [first.id, second.id], remaining: [first, second]))

        let shown = try texts(view)
        XCTAssertTrue(shown.contains("One release checklist for every team"))
        XCTAssertTrue(shown.contains("Three teams keep their own checklist."))
        XCTAssertFalse(shown.contains("Automate the weekly QA status mail"))
        let inspected = try view.inspect()
        XCTAssertTrue(try inspected.find(button: "Keep").buttonStyle() is KitPrimaryButtonStyle)
        XCTAssertTrue(try inspected.find(button: "Drop").buttonStyle() is KitSecondaryButtonStyle)
        XCTAssertTrue(try inspected.find(button: "Later").buttonStyle() is KitSecondaryButtonStyle)
        XCTAssertTrue(try inspected.find(button: "Make a Target…").buttonStyle() is KitQuietButtonStyle)
        XCTAssertThrowsError(try inspected.find(button: "Next 13"))
    }

    func testWritingDisablesTheVerdictButtons() throws {
        let idea = try insert()
        let inspected = try pane(state(batchIDs: [idea.id], remaining: [idea]), isWriting: true).inspect()
        for title in IdeaBatchPress.allCases.map(\.title) {
            XCTAssertTrue(try inspected.find(button: title).isDisabled(), title)
        }
    }

    func testBatchDoneShowsNextWithSize() throws {
        let done = pane(state(batchIDs: [1, 2], remaining: [], nextAvailable: 13))
        XCTAssertTrue(try texts(done).contains("Today’s batch done"))
        XCTAssertNoThrow(try done.inspect().find(button: "Next 13"))

        let small = pane(state(batchIDs: [1], remaining: [], nextAvailable: 5, size: 5))
        XCTAssertNoThrow(try small.inspect().find(button: "Next 5"))
    }

    func testNothingLeftHidesNext() throws {
        let view = pane(state(batchIDs: [1, 2], remaining: [], nextAvailable: 0))
        let shown = try texts(view)
        XCTAssertTrue(shown.contains("Nothing left to judge from the last 30 days"))
        XCTAssertThrowsError(try view.inspect().find(button: "Next 13"))
        XCTAssertThrowsError(try view.inspect().find(button: "Keep"))
    }

    func testBacklogButtonTitle() throws {
        let view = pane(state(batchIDs: [1], remaining: [], backlogCount: 140))
        XCTAssertNoThrow(try view.inspect().find(button: "Backlog · 140"))
    }

    func testKeptTodayListsKeptIdeas() throws {
        let kept = try insert(title: "Move the vendor call notes into Confluence", status: "active")
        let view = pane(state(batchIDs: [kept.id], remaining: [], keptToday: [kept]))
        let shown = try texts(view)
        XCTAssertTrue(shown.contains("Kept today"))
        XCTAssertTrue(shown.contains("Move the vendor call notes into Confluence"))

        let none = pane(state(batchIDs: [1], remaining: []))
        XCTAssertFalse(try texts(none).contains("Kept today"))
    }

    func testErrorShowsInBanner() throws {
        let view = pane(state(batchIDs: [1], remaining: []), errorMessage: "Failed to approve idea: gone")
        XCTAssertNoThrow(try view.inspect().find(WriteErrorBanner.self))
    }

    func testChipNamesKindSourceAndAge() throws {
        let idea = try insert()
        let chip = IdeaBatchPane.chipText(idea, sourceLabel: "Slack")
        XCTAssertTrue(chip.hasPrefix("idea · from Slack, "), chip)
        XCTAssertEqual(IdeaBatchPane.chipText(idea, sourceLabel: "").components(separatedBy: " · ").first, "idea")
        XCTAssertFalse(IdeaBatchPane.chipText(idea, sourceLabel: "").contains("from"))
    }
}

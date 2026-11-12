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

    private func pane(_ state: IdeaBatchState, isWriting: Bool = false,
                      failure: IdeaBatchFailure? = nil) -> IdeaBatchPane {
        IdeaBatchPane(state: state, isWriting: isWriting, failure: failure,
                      loadFacts: { _ in nil }, onPress: { _, _ in .landed(targetID: nil) }, onNext: {},
                      onBacklog: {}, onDismissError: {})
    }

    /// Lets the pane's press task finish (bounded).
    private func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            await Task.yield()
        }
    }

    private func texts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
    }

    // MARK: - Dispatch

    func testKeepWritesActive() async throws {
        let idea = try insert()
        let result = await ideas.press(.keep, on: idea)
        XCTAssertEqual(result, .landed(targetID: nil))
        XCTAssertEqual(try stored(idea.id).status, .active)
    }

    func testDropWritesRejectedNotDropped() async throws {
        let idea = try insert()
        let result = await ideas.press(.drop, on: idea)
        XCTAssertEqual(result, .landed(targetID: nil))
        XCTAssertEqual(try stored(idea.id).status, .rejected)
    }

    func testLaterWritesNotNowWithoutDate() async throws {
        let idea = try insert()
        let result = await ideas.press(.later, on: idea)
        XCTAssertEqual(result, .landed(targetID: nil))
        let after = try stored(idea.id)
        XCTAssertEqual(after.status, .notNow)
        XCTAssertEqual(after.snoozeUntil, "")
    }

    func testMakeTargetConvertsAndReturnsTheTarget() async throws {
        let idea = try insert()
        let pressed = await ideas.press(.makeTarget, on: idea)
        guard case .landed(let targetID?) = pressed else { return XCTFail("\(pressed)") }
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
            guard case .landed = pressed else { return XCTFail("\(press.title): \(pressed)") }
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
        XCTAssertEqual(results.filter { $0 == .landed(targetID: nil) }.count, 1)
        XCTAssertEqual(results.filter { $0 == .didNotRun }.count, 1)
        XCTAssertEqual(try stored(idea.id).status, .active)

        // A press while the card's verdict key is held does nothing.
        let other = try insert(title: "Another idea")
        let nested = await ideas.pendingWrites.run(InboxIdeaPane.writeKey(other.id)) {
            await ideas.press(.drop, on: other)
        }
        XCTAssertEqual(nested, .didNotRun)
        XCTAssertEqual(try stored(other.id).status, .proposed)
    }

    /// The Inbox's re-read runs under the verdict key: a press on the card
    /// still shown from before it (Make a Target… on a stale Backlog row)
    /// writes nothing, so no second target is made.
    func testKeyHeldThroughTheReRead() async throws {
        let idea = try insert()
        var heldDuringReRead = false
        var pressDuringReRead: IdeaBatchPressOutcome?
        let pressed = await ideas.press(.makeTarget, on: idea) {
            heldDuringReRead = self.ideas.isPressing(idea.id)
            pressDuringReRead = await self.ideas.press(.makeTarget, on: idea)
        }
        guard case .landed(_?) = pressed else { return XCTFail("\(pressed)") }
        XCTAssertTrue(heldDuringReRead)
        XCTAssertEqual(pressDuringReRead, .didNotRun)
        let targets = try await dbManager.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM targets WHERE source_type = 'idea'")
        }
        XCTAssertEqual(targets, 1)
        XCTAssertFalse(ideas.isPressing(idea.id))
    }

    /// Make a Target… while a conversion of the idea started elsewhere (the
    /// Ideas tab) is pending does not run, and the card counts as writing.
    func testMakeTargetWhileConvertingElsewhereDoesNotRun() async throws {
        let idea = try insert()
        var pressed: IdeaBatchPressOutcome?
        var writing = false
        _ = await ideas.pendingWrites.run(IdeasViewModel.convertKey(idea.id)) {
            writing = ideas.isPressing(idea.id)
            pressed = await ideas.press(.makeTarget, on: idea)
        }
        XCTAssertTrue(writing)
        XCTAssertEqual(pressed, .didNotRun)
        XCTAssertEqual(try stored(idea.id).status, .proposed)
    }

    /// A failed press returns its own text and leaves the Ideas lists'
    /// `errorMessage` alone; no re-read follows a press that did not run.
    func testFailedPressReturnsItsOwnText() async throws {
        let idea = try insert()
        try await dbManager.dbPool.write { db in try db.execute(sql: "DELETE FROM ideas WHERE id = ?", arguments: [idea.id]) }
        var reReads = 0
        let pressed = await ideas.press(.keep, on: idea) { reReads += 1 }
        guard case .failed(let text) = pressed else { return XCTFail("\(pressed)") }
        XCTAssertTrue(text.hasPrefix("Failed to approve idea"), text)
        XCTAssertNil(ideas.errorMessage)
        XCTAssertEqual(reReads, 1)

        _ = await ideas.pendingWrites.run(InboxIdeaPane.writeKey(idea.id)) {
            _ = await ideas.press(.drop, on: idea) { reReads += 1 }
        }
        XCTAssertEqual(reReads, 1)
    }

    // MARK: - Press gate

    /// The card that was pressed takes no second press until another card is
    /// shown (or its press failed or did not run): K K, or K then D, before
    /// the batch re-reads, writes one verdict.
    func testGateAdmitsOnePressPerShownCard() {
        var gate = IdeaBatchPressGate()
        XCTAssertTrue(gate.admit(1, isWriting: false))
        XCTAssertFalse(gate.admit(1, isWriting: false))
        XCTAssertFalse(gate.admit(2, isWriting: true))
        XCTAssertTrue(gate.admit(2, isWriting: false))
        gate.release()
        XCTAssertTrue(gate.admit(2, isWriting: false))
    }

    /// The view's own gate: Keep tapped twice on one card hands one press
    /// out; a landed press keeps the card closed until another one shows.
    func testViewTakesOnePressPerCard() async throws {
        let idea = try insert()
        var presses: [IdeaBatchPress] = []
        let gate = IdeaBatchPressGate.Box()
        var view = IdeaBatchPane(
            state: state(batchIDs: [idea.id], remaining: [idea]), isWriting: false, failure: nil,
            loadFacts: { _ in nil },
            onPress: { press, _ in presses.append(press); return .landed(targetID: nil) },
            onNext: {}, onBacklog: {}, onDismissError: {})
        view.gateOverride = gate
        let inspected = try view.inspect()

        try inspected.find(button: "Keep").tap()
        try inspected.find(button: "Keep").tap()
        try inspected.find(button: "Drop").tap()
        await settle { presses.count == 1 }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(presses, [.keep])
        XCTAssertEqual(gate.value.pressedID, idea.id)
    }

    /// A press that failed or did not run leaves the card pressable.
    func testFailedOrNotRunPressReleasesTheCard() async throws {
        let idea = try insert()
        for outcome in [IdeaBatchPressOutcome.failed("Could not save the verdict"), .didNotRun] {
            var presses: [IdeaBatchPress] = []
            let gate = IdeaBatchPressGate.Box()
            var view = IdeaBatchPane(
                state: state(batchIDs: [idea.id], remaining: [idea]), isWriting: false, failure: nil,
                loadFacts: { _ in nil },
                onPress: { press, _ in presses.append(press); return outcome },
                onNext: {}, onBacklog: {}, onDismissError: {})
            view.gateOverride = gate
            let inspected = try view.inspect()

            try inspected.find(button: "Keep").tap()
            await settle { gate.value.pressedID == nil }
            XCTAssertNil(gate.value.pressedID, "\(outcome)")
            try inspected.find(button: "Drop").tap()
            await settle { presses.count == 2 }
            XCTAssertEqual(presses, [.keep, .drop], "\(outcome)")
        }
    }

    /// The card's own failure shows with **Try Again**, which sends the same
    /// press again; another card's failure is not shown.
    func testFailureShowsWithTryAgainResendingThePress() async throws {
        let idea = try insert()
        var presses: [IdeaBatchPress] = []
        var dismissed = false
        let view = IdeaBatchPane(
            state: state(batchIDs: [idea.id], remaining: [idea]), isWriting: false,
            failure: IdeaBatchFailure(ideaID: idea.id, press: .later, message: "Failed to snooze idea: busy"),
            loadFacts: { _ in nil },
            onPress: { press, _ in presses.append(press); return .landed(targetID: nil) },
            onNext: {}, onBacklog: {}, onDismissError: { dismissed = true })
        let banner = try view.inspect().find(WriteErrorBanner.self)
        XCTAssertNoThrow(try banner.find(text: "Failed to snooze idea: busy"))

        try banner.find(button: "Try Again").tap()
        await settle { !presses.isEmpty }
        XCTAssertEqual(presses, [.later])

        try banner.findAll(ViewType.Button.self).last?.tap()
        XCTAssertTrue(dismissed)

        let other = pane(state(batchIDs: [idea.id], remaining: [idea]),
                         failure: IdeaBatchFailure(ideaID: idea.id + 1, press: .keep, message: "Failed"))
        XCTAssertThrowsError(try other.inspect().find(WriteErrorBanner.self))
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

    func testChipNamesKindSourceAndAge() throws {
        let idea = try insert()
        let chip = IdeaBatchPane.chipText(idea, sourceLabel: "Slack")
        XCTAssertTrue(chip.hasPrefix("idea · from Slack, "), chip)
        XCTAssertEqual(IdeaBatchPane.chipText(idea, sourceLabel: "").components(separatedBy: " · ").first, "idea")
        XCTAssertFalse(IdeaBatchPane.chipText(idea, sourceLabel: "").contains("from"))
    }
}

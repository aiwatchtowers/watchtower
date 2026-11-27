import GRDB
import SwiftUI
import ViewInspector
import XCTest
import ChatUI
import WatchtowerChatText
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The "Not clear?" views (spec 2026-11-24 "Where the control is", "The
/// chat view"): the entry's visibility, the composer's Esc and the drawer's
/// two layers.
@MainActor
final class AskExplainViewTests: XCTestCase {
    private var fx: AskExplainFixture!

    override func setUpWithError() throws {
        fx = try AskExplainFixture()
    }

    override func tearDown() {
        fx.cleanup()
    }

    /// Esc in the composer leaves an empty one for the question and never
    /// stops the turn (Stop stays on the composer's button); with a draft it
    /// does nothing.
    func testComposerEscapeNeverStops() async throws {
        let ask = try fx.insertAsk()
        await fx.vm.openExplain(ask, item: .question(1))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(1)))
        await engine.started()
        XCTAssertTrue(engine.isBusy)
        var backs = 0
        let escape = AskExplainChatView.composerEscape(engine: engine) { backs += 1 }

        escape()
        XCTAssertEqual(backs, 1)
        XCTAssertTrue(engine.isBusy, "the turn runs on")
        XCTAssertEqual(fx.ai.calls.count, 1)

        engine.draft = "What does park mean?"
        escape()
        XCTAssertEqual(backs, 1, "a draft keeps the chat")
        XCTAssertTrue(engine.isBusy)
        XCTAssertEqual(engine.draft, "What does park mean?")

        fx.ai.emit(.text("It decides."), .done)
        fx.ai.finish()
        await waitForCondition { !engine.isBusy }
        await engine.finished()
    }

    /// A first turn whose CLI exits before the reply row exists leaves only
    /// the engine's banner: the chat shows it with Retry, and Retry (an
    /// open) starts the first turn again on the empty history.
    func testFirstTurnFailingBeforeStartOffersRetry() async throws {
        struct EarlyExit: LocalizedError { var errorDescription: String? { "the CLI exited" } }
        let ask = try fx.insertAsk()
        fx.ai.persistStartError = EarlyExit()
        await fx.vm.openExplain(ask, item: .question(1))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(1)))
        await engine.finished()
        XCTAssertTrue(engine.messages.isEmpty, "no reply row")
        XCTAssertNil(fx.vm.explainErrors[AskExplainSubject(askID: ask.id, item: .question(1))])
        let failure = try XCTUnwrap(AskExplainChatView.startFailure(engine))
        XCTAssertTrue(failure.contains("the CLI exited"), failure)
        XCTAssertEqual(AskExplainChatView.failureLine(openError: nil, engine: engine), failure,
                       "the engine's banner already says what failed: no \"Couldn't explain:\" in front")
        XCTAssertEqual(AskExplainChatView.failureLine(openError: "This workbench no longer exists.", engine: engine),
                       "Couldn't explain: This workbench no longer exists.", "a failed open keeps the prefix")
        engine.draft = "What does park mean?"
        XCTAssertEqual(AskExplainChatView.startFailure(engine), failure, "typing keeps the Retry row")
        engine.draft = ""

        fx.ai.persistStartError = nil
        await fx.vm.openExplain(ask, item: .question(1))
        await engine.started()
        XCTAssertEqual(fx.hiddenTurns.count, 2, "Retry starts the first turn again")
        XCTAssertNil(AskExplainChatView.startFailure(engine), "nothing while it runs")
        fx.ai.emit(.text("It decides."), .done)
        fx.ai.finish()
        await waitForCondition { !engine.isBusy }
        await engine.finished()
        XCTAssertNil(AskExplainChatView.startFailure(engine))
    }

    /// A first turn that never started shows its failure once (board #2383):
    /// the row with Retry, not the composer's status line as well. An owner
    /// send that failed the same way keeps the composer's own status.
    func testItemFirstTurnFailingBeforeStartShowsItsErrorOnce() async throws {
        struct EarlyExit: LocalizedError { var errorDescription: String? { "the CLI exited" } }
        let ask = try fx.insertAsk()
        fx.ai.persistStartError = EarlyExit()
        await fx.vm.openExplain(ask, item: .question(1))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(1)))
        await engine.finished()
        XCTAssertNotNil(AskExplainChatView.failureLine(openError: nil, engine: engine), "the row shows it")
        XCTAssertTrue(AskExplainChatView.composerHidesError(engine))
        XCTAssertNil(EmbeddedChatComposer.status(of: engine, hidesError: AskExplainChatView.composerHidesError(engine)),
                     "not again under the composer")
        XCTAssertNotNil(EmbeddedChatComposer.status(of: engine), "other chats keep the status line")

        XCTAssertTrue(engine.send("Will my scripts be queued?"))
        await engine.finished()
        XCTAssertFalse(AskExplainChatView.composerHidesError(engine))
        XCTAssertEqual(EmbeddedChatComposer.status(of: engine, hidesError: AskExplainChatView.composerHidesError(engine)),
                       engine.bannerError.map { .error($0) }, "an owner send's failure stays on the composer")
    }

    /// The chat view hands its composer `hidesError` from
    /// `composerHidesError` (board #2383): dropping that wiring fails here.
    func testChatViewWiresTheComposersHiddenError() async throws {
        struct EarlyExit: LocalizedError { var errorDescription: String? { "the CLI exited" } }
        let ask = try fx.insertAsk()
        fx.ai.persistStartError = EarlyExit()
        await fx.vm.openExplain(ask, item: .question(1))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(1)))
        await engine.finished()
        XCTAssertTrue(chatView(ask, .question(1), engine).composer.hidesError)
        XCTAssertTrue(engine.send("Why?"))
        await engine.finished()
        XCTAssertFalse(chatView(ask, .question(1), engine).composer.hidesError)
    }

    /// The pane's Retry, used by both failure layouts and handed to the chat
    /// view, is nil once the workbench is gone (board #2383).
    func testPaneOffersNoRetryForAGoneWorkbench() async throws {
        let ask = try fx.insertAsk()
        fx.tower.refuse(.chatNew, with: "The database is busy.")
        await fx.vm.openExplain(ask, item: .question(1))
        XCTAssertNotNil(AskExplainPane(asks: fx.vm, ask: ask, item: .question(1)) {}.retryIfItCanHelp, "another failure: Retry")

        fx.tower.refuse(.chatNew, with: nil)
        await fx.vm.openExplain(ask, item: .question(1))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(1)))
        XCTAssertNotNil(AskExplainPane(asks: fx.vm, ask: ask, item: .question(1)) {}.chatView(engine).onRetry)

        let projectID = fx.projectID
        try await fx.pool.write { db in
            try db.execute(sql: "DELETE FROM owner_asks WHERE project_id = ?", arguments: [projectID])
            try db.execute(sql: "DELETE FROM workbench_folders WHERE workbench_id = ?", arguments: [projectID])
            try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [projectID])
        }
        fx.vm.closeExplain(ask.id)
        await fx.vm.openExplain(ask, item: .question(1))
        let pane = AskExplainPane(asks: fx.vm, ask: ask, item: .question(1)) {}
        XCTAssertEqual(AskExplainPane.shown(hasEngine: fx.vm.explainEngine(for: ask, item: .question(1)) != nil,
                                            error: fx.vm.explainErrors[AskExplainSubject(askID: ask.id, item: .question(1))]),
                       .failure("This workbench no longer exists."))
        XCTAssertNil(pane.retryIfItCanHelp, "a final state: no Retry")
        XCTAssertNil(pane.chatView(engine).onRetry)
        await engine.started()
        fx.ai.emit(.text("It decides."), .done)
        fx.ai.finish()
        await waitForCondition { !engine.isBusy }
        await engine.finished()
    }

    /// An owner send that fails before any row is not a hidden turn: no
    /// Retry row (it would send the explanation prompt instead), even once
    /// the restored draft is cleared; the composer keeps its own status.
    func testOwnerSendFailingBeforeStartOffersNoRetryRow() async throws {
        struct EarlyExit: LocalizedError { var errorDescription: String? { "the CLI exited" } }
        let ask = try fx.insertAsk()
        fx.ai.persistStartError = EarlyExit()
        await fx.vm.openExplain(ask, item: .question(1))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(1)))
        await engine.finished()
        XCTAssertNotNil(AskExplainChatView.startFailure(engine), "the hidden first turn failed")

        XCTAssertTrue(engine.send("Will my scripts be queued?"))
        await engine.finished()
        XCTAssertTrue(engine.messages.isEmpty)
        XCTAssertEqual(engine.draft, "Will my scripts be queued?", "the owner's text is back in the composer")
        XCTAssertNotNil(engine.bannerError, "the composer's own status says it")
        XCTAssertNil(AskExplainChatView.startFailure(engine))
        engine.draft = ""
        XCTAssertNil(AskExplainChatView.startFailure(engine), "clearing the restored question offers no Retry")
    }

    /// Before the engine: a spinner while the conversation is found or
    /// created, the open's failure once it failed; the chat's own
    /// indicators take over once the engine is there.
    func testPaneShowsASpinnerWhileFindingTheChat() {
        XCTAssertEqual(AskExplainPane.shown(hasEngine: false, error: nil), .finding)
        XCTAssertEqual(AskExplainPane.shown(hasEngine: false, error: "gone"), .failure("gone"))
        XCTAssertEqual(AskExplainPane.shown(hasEngine: true, error: nil), .chat)
        XCTAssertEqual(AskExplainPane.shown(hasEngine: true, error: "gone"), .chat, "the chat shows the error itself")
    }

    /// A failure after the reply row exists keeps the feed's own card.
    func testFailureWithAReplyRowKeepsTheFeedCard() async throws {
        let ask = try fx.insertAsk()
        await fx.vm.openExplain(ask, item: .question(1))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(1)))
        await engine.started()
        fx.ai.emit(.error("Not logged in"), .done)
        fx.ai.finish()
        await waitForCondition { !engine.isBusy }
        await engine.finished()
        XCTAssertFalse(engine.messages.isEmpty)
        XCTAssertNil(AskExplainChatView.startFailure(engine))
    }

    // MARK: - Entries per item (spec 2026-11-27 D1, D2)

    /// Each question of the ask ends with its own entry, opening that
    /// question by its position; a question not in the ask opens nothing.
    func testEachQuestionGetsAnEntry() throws {
        let ask = try fx.insertAsk()
        let questions = ask.payload.questions
        XCTAssertEqual(questions.map { AskExplainItem.forQuestion(id: $0.id, in: ask) },
                       [.question(1), .question(2), .question(3)])
        let card = ChatQuestionCard(questions: questions)
        let picks = Binding<[String: ChatQuestionAnswer.Entry]>.constant([:])
        func questionCard(_ explain: (ask: OwnerAsk, open: (AskExplainItem) -> Void)?) -> some View {
            QuestionPartView(card: card, draft: OwnerAskDrawer.questionDraft(
                picks: picks, editable: true, onKey: nil, fieldFocus: nil, stop: nil, onLeaveField: nil,
                explain: explain))
                .environment(\.chatUIStyle, DesignKitChatStyle(look: .ask))
        }
        let entry = height(AskExplainEntry(item: .question(1)) {})
        XCTAssertGreaterThan(entry, 0)
        XCTAssertGreaterThanOrEqual(height(questionCard((ask, { _ in }))) - height(questionCard(nil)), 3 * entry,
                                    "an entry under each of the three questions")

        var opened: [AskExplainItem] = []
        let action = try XCTUnwrap(OwnerAskDrawer.explainAction(for: questions[1], in: ask) { opened.append($0) })
        action()
        XCTAssertEqual(opened, [.question(2)])
        let stranger = ChatQuestion(id: "elsewhere", question: "Which?", options: [])
        XCTAssertNil(OwnerAskDrawer.explainAction(for: stranger, in: ask) { opened.append($0) })
    }

    /// Each step of a check has its own `?`, named for its 1-based
    /// position; the second one opens step 2. Without an opener, none.
    func testEachStepGetsAnEntry() throws {
        let check = try fx.insertAsk(kind: "check")
        var opened: [AskExplainItem] = []
        let body = OwnerAskChecklistBody(items: check.payload.checklist, marks: [:], notes: [:], editable: true) {
            opened.append($0)
        }
        let entries = try stepEntries(body)
        XCTAssertEqual(entries.map(\.label), ["Not clear? Step 1", "Not clear? Step 2", "Not clear? Step 3"])
        try XCTUnwrap(entries.dropFirst().first).button.tap()
        XCTAssertEqual(opened, [.step(2)])
        let without = OwnerAskChecklistBody(items: check.payload.checklist, marks: [:], notes: [:], editable: true)
        XCTAssertTrue(try stepEntries(without).isEmpty)
        XCTAssertEqual(OwnerAskChecklistBody.stepItem(index: 1), .step(2))
        XCTAssertEqual(OwnerAskChecklistBody.stepItem(index: 0), .step(1))
    }

    /// The drawer's gate (`AskExplainPresentation.showsEntry`): a review
    /// ask, though its payload carries questions, draws no entry.
    func testNoEntriesOnReviewAsk() async throws {
        let review = try fx.insertAsk(kind: "review")
        XCTAssertFalse(review.payload.questions.isEmpty)
        let entries = try await drawerEntries(review, hasCLI: true)
        XCTAssertEqual(entries, [])
    }

    /// Without a CLI the drawer draws no entry on a question or a check.
    func testNoEntriesWithoutACLI() async throws {
        let (question, check) = (try fx.insertAsk(), try fx.insertAsk(kind: "check"))
        let questionEntries = try await drawerEntries(question, hasCLI: false)
        let checkEntries = try await drawerEntries(check, hasCLI: false)
        let withCLI = try await drawerEntries(question, hasCLI: true)
        XCTAssertEqual(questionEntries, [])
        XCTAssertEqual(checkEntries, [])
        XCTAssertEqual(withCLI, ["Not clear? Question 1", "Not clear? Question 2", "Not clear? Question 3"], "with a CLI")
    }

    /// A closed question ask and a closed check ask keep their entries.
    func testEntriesOnAClosedAsk() async throws {
        let projectID = fx.projectID
        let payload = AskExplainFixture.threeQuestions
        let steps = AskExplainFixture.threeSteps
        let (questionID, checkID) = try await fx.pool.write { db in
            (try TestDatabase.insertOwnerAsk(db, projectID: projectID, payload: payload, status: "answered",
                                             answer: #"{"note":"Fine"}"#),
             try TestDatabase.insertOwnerAsk(db, projectID: projectID, kind: "check", payload: steps, status: "answered",
                                             answer: #"{"note":"Fine"}"#))
        }
        let (readQuestion, readCheck) = try await fx.pool.read {
            (try OwnerAskQueries.ask($0, id: questionID, projectID: projectID),
             try OwnerAskQueries.ask($0, id: checkID, projectID: projectID))
        }
        let closed = try XCTUnwrap(readQuestion)
        let closedCheck = try XCTUnwrap(readCheck)
        XCTAssertFalse(closed.isOpen)
        XCTAssertFalse(closedCheck.isOpen)
        let closedEntries = try await drawerEntries(closed, hasCLI: true)
        let checkEntries = try await drawerEntries(closedCheck, hasCLI: true)
        XCTAssertEqual(closedEntries, ["Not clear? Question 1", "Not clear? Question 2", "Not clear? Question 3"])
        XCTAssertEqual(checkEntries, ["Not clear? Step 1", "Not clear? Step 2", "Not clear? Step 3"])
    }

    /// Every entry's accessibility label names its item; the question's
    /// visible label stays "Not clear?".
    func testEntryAccessibilityLabelsNameTheItem() {
        XCTAssertEqual(AskExplainEntry.accessibilityLabel(.question(2)), "Not clear? Question 2")
        XCTAssertEqual(AskExplainEntry.accessibilityLabel(.step(3)), "Not clear? Step 3")
        XCTAssertEqual(AskExplainCopy.entry, "Not clear?")
    }

    /// The card's chip says what the ask's question card says.
    func testRecommendedMatchesTheQuestionCard() {
        XCTAssertEqual(AskExplainCopy.recommended, QuestionPartView.recommendedLabel)
    }

    // MARK: - The chat about one item (spec D5–D8, D13)

    func testStripAndPlaceholderFollowTheItem() async throws {
        XCTAssertTrue(AskExplainChatView.stripLabels(.question(2)) == ("Back to question", "Question 2"))
        XCTAssertTrue(AskExplainChatView.stripLabels(.step(2)) == ("Back to check", "Step 2"))
        let check = try fx.insertAsk(kind: "check")
        await fx.vm.openExplain(check, item: .step(2))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: check, item: .step(2)))
        XCTAssertEqual(chatView(check, .step(2), engine).composer.placeholder, "Ask about this step…")
        XCTAssertEqual(chatView(check, .question(1), engine).composer.placeholder, "Ask about this question…")
        await finishTurn(engine)
    }

    /// The item's card sits under the strip whatever the pane shows: the
    /// spinner, a failed open, the chat.
    func testCardShowsInEveryPaneState() async throws {
        let ask = try fx.insertAsk()
        let card = try XCTUnwrap(AskExplainCard.make(ask: ask, item: .question(2)))
        await fx.vm.openExplain(ask, item: .question(2))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(2)))
        for shown in [AskExplainPane.Shown.finding, .failure("The database is busy."), .chat] {
            XCTAssertTrue(AskExplainPane.showsCard(shown), "\(shown)")
            XCTAssertGreaterThan(height(paneState(shown, ask, engine, card: card)),
                                 height(paneState(shown, ask, engine, card: nil)), "\(shown)")
        }
        await finishTurn(engine)
    }

    /// The strip and the card are drawn once, above whatever the state
    /// shows: a card expanded while the chat is found stays expanded when
    /// the chat loads (its view, and so its state, is the same).
    func testCardHeaderStaysAcrossPaneStates() async throws {
        let ask = try fx.insertAsk()
        let card = try XCTUnwrap(AskExplainCard.make(ask: ask, item: .question(2)))
        await fx.vm.openExplain(ask, item: .question(2))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(2)))
        for shown in [AskExplainPane.Shown.finding, .failure("The database is busy."), .chat] {
            let stack = try paneState(shown, ask, engine, card: card).inspect().vStack()
            let header = try stack.view(AskExplainItemHeader.self, 0)
            XCTAssertEqual(try header.actualView().subject, AskExplainSubject(askID: ask.id, item: .question(2)), "\(shown)")
            XCTAssertNoThrow(try header.find(AskExplainItemCard.self), "\(shown)")
        }
        await finishTurn(engine)
    }

    /// The card keeps its expansion as the pane's state moves on (finding →
    /// chat): SwiftUI keeps a view's state while it holds the same place in
    /// the view's type, so the header must sit beside the state switch, not
    /// inside each branch. (A live click cannot be driven here: a window
    /// that is never ordered in delivers no synthesized click to a SwiftUI
    /// button and exposes no accessibility tree, and ViewHosting orders a
    /// window in, which tests must not do.)
    func testCardHeaderSitsOutsideTheStateSwitch() async throws {
        let ask = try fx.insertAsk()
        let card = try XCTUnwrap(AskExplainCard.make(ask: ask, item: .question(2)))
        await fx.vm.openExplain(ask, item: .question(2))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(2)))
        for shown in [AskExplainPane.Shown.finding, .failure("The database is busy."), .chat] {
            let layout = String(describing: type(of: paneState(shown, ask, engine, card: card)))
            XCTAssertTrue(layout.hasPrefix("VStack<TupleView<(AskExplainItemHeader, _ConditionalContent<"), layout)
        }
        await finishTurn(engine)
    }

    /// The card's identity is its subject: another item's chat, of this ask
    /// or of another, starts it collapsed.
    func testCardExpansionResetsPerSubject() throws {
        let card = AskExplainCard.question(text: "Which store?", options: [])
        func cardID(_ subject: AskExplainSubject) throws -> AnyHashable {
            try AskExplainItemHeader(subject: subject, card: card) {}.inspect().find(AskExplainItemCard.self).id()
        }
        let first = AskExplainSubject(askID: 1, item: .question(2))
        XCTAssertEqual(try cardID(first), AnyHashable(first))
        XCTAssertNotEqual(try cardID(first), try cardID(AskExplainSubject(askID: 2, item: .question(2))),
                          "the same item of another ask")
        XCTAssertNotEqual(try cardID(first), try cardID(AskExplainSubject(askID: 1, item: .question(3))))
    }

    /// Past the clamp a card is cut to it with Show more under it; a short
    /// one shows whole, with no toggle.
    func testCardClampsALongQuestion() {
        let long = AskExplainCard.question(
            text: AskExplainItemsMock.longQuestion.text,
            options: AskExplainItemsMock.longQuestion.options.map { .init(label: $0.label, recommended: $0.recommended) })
        let toggle = height(Button {} label: {
            Label(AskExplainCopy.showMore, systemImage: "chevron.down").font(.caption)
        }.buttonStyle(KitQuietButtonStyle(label: .secondary)))
        let padding = 2 * Spacing.cozy
        let longHeight = settledHeight(AskExplainItemCard(card: long))
        let whole = height(AskExplainItemCardContent(card: long).frame(width: 400 - 2 * Spacing.medium))
        XCTAssertGreaterThan(whole, AskExplainCardLayout.clampHeight, "the sample is taller than the clamp")
        XCTAssertLessThan(longHeight, whole + padding, "cut, not shown whole")
        XCTAssertLessThanOrEqual(longHeight, AskExplainCardLayout.clampHeight + Spacing.small + toggle + padding + 2,
                                 "clamped, with the toggle row")
        XCTAssertGreaterThan(longHeight, AskExplainCardLayout.clampHeight, "the clamp, not less")
        let short = AskExplainCard.question(text: "Which store?", options: [.init(label: "Postgres", recommended: true),
                                                                            .init(label: "SQLite", recommended: false)])
        XCTAssertLessThan(settledHeight(AskExplainItemCard(card: short)), AskExplainCardLayout.clampHeight + padding,
                          "whole, no toggle row")
    }

    /// The question view stays in the tree, hidden, under the chat: its
    /// scroll and the answer bar's state survive.
    func testQuestionLayerStaysInTree() {
        let shown = OwnerAskDrawerExplainLayers.layers(explaining: true)
        XCTAssertEqual(shown.map(\.layer), [.question, .chat])
        XCTAssertEqual(shown.map(\.visible), [false, true])
        let question = OwnerAskDrawerExplainLayers.layers(explaining: false)
        XCTAssertEqual(question.map(\.layer), [.question])
        XCTAssertEqual(question.map(\.visible), [true])
    }

    private func height(_ view: some View) -> CGFloat {
        ViewRenderProbe.fittingHeight(view, width: 400)
    }

    /// Lays the hosted view out and lets its state settle: run-loop passes
    /// that never wait.
    private func settle(_ host: NSView) {
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date())
        }
    }

    /// The entries `OwnerAskDrawer` draws for `ask`, by accessibility label,
    /// with or without a CLI (`asks.chats`).
    private func drawerEntries(_ ask: OwnerAsk, hasCLI: Bool) async throws -> [String] {
        let vm = WorkbenchesViewModel(dbPool: fx.pool, cli: nil, defaults: fx.defaults)
        vm.asks.chats = hasCLI ? fx.center : nil
        await vm.asks.load(projectID: fx.projectID)
        return try OwnerAskDrawer(vm: vm, ask: ask).inspect().findAll(AskExplainEntry.self).map {
            try $0.find(ViewType.Button.self).accessibilityLabel().string()
        }
    }

    /// The fitting height once the view's measured state has settled (the
    /// card reads its content height after a first layout).
    private func settledHeight(_ view: some View) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        settle(host)
        return ceil(host.fittingSize.height)
    }

    private func chatView(_ ask: OwnerAsk, _ item: AskExplainItem, _ engine: EmbeddedChatEngine) -> AskExplainChatView {
        AskExplainChatView(ask: ask, item: item, engine: engine) {}
    }

    /// One pane state of `ask`'s question 2, with or without its card.
    private func paneState(
        _ shown: AskExplainPane.Shown, _ ask: OwnerAsk, _ engine: EmbeddedChatEngine, card: AskExplainCard?
    ) -> some View {
        AskExplainPane.layout(shown, subject: AskExplainSubject(askID: ask.id, item: .question(2)), card: card,
                              onRetry: nil, onBack: {}, chat: {
            AskExplainChatView(ask: ask, item: .question(2), engine: engine) {}
        })
    }

    /// The step entries of a checklist: each button and its accessibility label.
    private func stepEntries(_ body: OwnerAskChecklistBody) throws -> [(label: String, button: InspectableView<ViewType.Button>)] {
        try body.inspect().findAll(AskExplainEntry.self).map { entry in
            let button = try entry.find(ViewType.Button.self)
            return (try button.accessibilityLabel().string(), button)
        }
    }

    private func finishTurn(_ engine: EmbeddedChatEngine) async {
        await engine.started()
        fx.ai.emit(.text("It decides."), .done)
        fx.ai.finish()
        await waitForCondition { !engine.isBusy }
        await engine.finished()
    }
}

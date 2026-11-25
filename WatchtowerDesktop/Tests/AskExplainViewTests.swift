import GRDB
import SwiftUI
import XCTest
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
        await fx.vm.openExplain(ask)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask))
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
        await fx.vm.openExplain(ask)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask))
        await engine.finished()
        XCTAssertTrue(engine.messages.isEmpty, "no reply row")
        XCTAssertNil(fx.vm.explainErrors[ask.id])
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
        await fx.vm.openExplain(ask)
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
    func testFirstTurnFailingBeforeStartShowsItsErrorOnce() async throws {
        struct EarlyExit: LocalizedError { var errorDescription: String? { "the CLI exited" } }
        let ask = try fx.insertAsk()
        fx.ai.persistStartError = EarlyExit()
        await fx.vm.openExplain(ask)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask))
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

    /// An owner send that fails before any row is not a hidden turn: no
    /// Retry row (it would send the explanation prompt instead), even once
    /// the restored draft is cleared; the composer keeps its own status.
    func testOwnerSendFailingBeforeStartOffersNoRetryRow() async throws {
        struct EarlyExit: LocalizedError { var errorDescription: String? { "the CLI exited" } }
        let ask = try fx.insertAsk()
        fx.ai.persistStartError = EarlyExit()
        await fx.vm.openExplain(ask)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask))
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
        await fx.vm.openExplain(ask)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask))
        await engine.started()
        fx.ai.emit(.error("Not logged in"), .done)
        fx.ai.finish()
        await waitForCondition { !engine.isBusy }
        await engine.finished()
        XCTAssertFalse(engine.messages.isEmpty)
        XCTAssertNil(AskExplainChatView.startFailure(engine))
    }

    func testEntryHiddenOnReviewAsk() throws {
        let review = try fx.insertAsk(kind: "review")
        XCTAssertEqual(height(AskExplainEntry(ask: review, hasCLI: true) {}), 0)
        let question = try fx.insertAsk()
        XCTAssertEqual(height(AskExplainEntry(ask: question, hasCLI: false) {}), 0, "no CLI, no entry")
    }

    func testEntryShownOnClosedQuestionAsk() throws {
        let projectID = fx.projectID
        let id = try fx.pool.write {
            try TestDatabase.insertOwnerAsk($0, projectID: projectID, status: "answered", answer: #"{"note":"Fine"}"#)
        }
        let closed = try XCTUnwrap(try fx.pool.read { try OwnerAskQueries.ask($0, id: id, projectID: projectID) })
        XCTAssertFalse(closed.isOpen)
        XCTAssertGreaterThan(height(AskExplainEntry(ask: closed, hasCLI: true) {}), 0)
        let check = try fx.insertAsk(kind: "check")
        XCTAssertGreaterThan(height(AskExplainEntry(ask: check, hasCLI: true) {}), 0)
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
}

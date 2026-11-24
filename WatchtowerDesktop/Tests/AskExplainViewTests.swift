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

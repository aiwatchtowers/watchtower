import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The per-ask "Not clear?" mode of `OwnerAsksViewModel` (spec 2026-11-24
/// "The chat view", "The first message", "Failure paths").
@MainActor
final class AskExplainModelTests: XCTestCase {
    private var fx: AskExplainFixture!

    override func setUpWithError() throws {
        fx = try AskExplainFixture()
    }

    override func tearDown() {
        fx.cleanup()
    }

    private func finishTurn(_ engine: EmbeddedChatEngine, text: String = "It decides the flag.") async {
        await engine.started()
        fx.ai.emit(.text(text), .done)
        fx.ai.finish()
        await waitForCondition { !engine.isBusy }
        await engine.finished()
    }

    func testOpenStartsHiddenTurnOnce() async throws {
        let ask = try fx.insertAsk()
        fx.vm.openDrawer(ask)
        await fx.vm.openExplain(ask)
        XCTAssertTrue(fx.vm.isExplaining(ask.id))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask))
        await engine.started()
        XCTAssertEqual(fx.ai.calls.count, 1)
        let call = try XCTUnwrap(fx.ai.calls.first)
        XCTAssertEqual(call.prompt, AskExplainPrompt.firstTurn)
        XCTAssertNil(call.persist?.ownerText, "hidden: no owner row")
        XCTAssertEqual(call.purpose, AskExplainKey.purpose)
        XCTAssertEqual(call.readFolder, "/tmp/acme-explain")
        XCTAssertNil(call.toolMode, "draft-only")
        await finishTurn(engine)

        fx.vm.closeExplain(ask.id)
        XCTAssertFalse(fx.vm.isExplaining(ask.id))
        await fx.vm.openExplain(ask)
        XCTAssertTrue(fx.vm.isExplaining(ask.id))
        XCTAssertEqual(fx.ai.calls.count, 1, "a chat with messages starts nothing")
    }

    func testOpenTwiceStartsOneHiddenTurn() async throws {
        let ask = try fx.insertAsk()
        async let first: Void = fx.vm.openExplain(ask)
        async let second: Void = fx.vm.openExplain(ask)
        _ = await (first, second)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask))
        await engine.started()
        XCTAssertEqual(fx.hiddenTurns.count, 1)
        XCTAssertEqual(fx.tower.calls(.chatNew).count, 1)
    }

    func testPartialFirstTurnOffersRetryOnly() async throws {
        let ask = try fx.insertAsk()
        let conversationID = try await AskExplainSurface.conversationID(ask: ask, dbPool: fx.pool, writes: fx.writes)
        try await fx.pool.write { db in
            _ = try TestDatabase.insertChatMessage(db, conversationID: conversationID, role: "assistant",
                                                   text: "It decides", status: "partial")
        }
        await fx.vm.openExplain(ask)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask))
        XCTAssertTrue(fx.ai.calls.isEmpty, "no second hidden turn on its own")
        XCTAssertFalse(engine.isBusy)
        XCTAssertTrue(engine.canRetry, "the partial reply offers Retry")

        engine.retry()
        await engine.started()
        XCTAssertEqual(fx.ai.calls.count, 1)
        XCTAssertTrue(fx.ai.calls[0].prompt.hasSuffix(AskExplainPrompt.firstTurn), "Retry reruns the hidden prompt")
        XCTAssertNil(fx.ai.calls[0].persist?.ownerText)
    }

    func testErrorRow() async throws {
        let ask = try fx.insertAsk()
        await fx.vm.openExplain(ask)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask))
        await engine.started()
        fx.ai.emit(.error("Not logged in · Please run /login"), .done)
        fx.ai.finish()
        await waitForCondition { !engine.isBusy }
        await engine.finished()
        let reply = try XCTUnwrap(try fx.rows(try XCTUnwrap(engine.spec.key.conversationID)).last)
        XCTAssertEqual(reply.status, "error")
        XCTAssertTrue(reply.errorMessage?.hasPrefix("Not logged in · Please run /login") == true,
                      "the real error, not a generic one: \(reply.errorMessage ?? "nil")")
        XCTAssertTrue(engine.canRetry)
    }

    func testModeIsPerAsk() async throws {
        let first = try fx.insertAsk(title: "A")
        let second = try fx.insertAsk(title: "B")
        fx.vm.openDrawer(first)
        await fx.vm.openExplain(first)
        fx.vm.openDrawer(second)
        XCTAssertFalse(fx.vm.isExplaining(second.id))
        XCTAssertTrue(fx.vm.isExplaining(first.id))
        await fx.vm.openExplain(second)
        XCTAssertTrue(fx.vm.isExplaining(second.id))

        fx.vm.closeDrawer(projectID: fx.projectID)
        XCTAssertFalse(fx.vm.isExplaining(first.id))
        XCTAssertFalse(fx.vm.isExplaining(second.id))
        XCTAssertTrue(fx.vm.explainOpen.isEmpty)
    }

    func testChatSurvivesAskClosing() async throws {
        let ask = try fx.insertAsk()
        fx.vm.openDrawer(ask)
        await fx.vm.load(projectID: fx.projectID)
        await fx.vm.openExplain(ask)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask))
        await engine.started()

        try await fx.pool.write { db in
            try db.execute(sql: "UPDATE owner_asks SET status = 'answered', answer = 'Yes' WHERE id = ?",
                           arguments: [ask.id])
        }
        await fx.vm.load(projectID: fx.projectID)
        XCTAssertTrue(fx.vm.isExplaining(ask.id))
        XCTAssertTrue(fx.vm.explainEngine(for: ask) === engine)
        XCTAssertTrue(engine.isBusy, "the running turn is untouched")
        XCTAssertEqual(fx.ai.calls.count, 1)
    }

    func testNoCLINoEntry() async throws {
        let ask = try fx.insertAsk()
        fx.vm.chats = nil
        await fx.vm.openExplain(ask)
        XCTAssertFalse(fx.vm.isExplaining(ask.id))
        XCTAssertNil(fx.vm.explainEngine(for: ask))
        XCTAssertTrue(fx.tower.calls(.chatNew).isEmpty)
        XCTAssertTrue(fx.ai.calls.isEmpty)
    }

    func testReviewAskOpensNoChat() async throws {
        let review = try fx.insertAsk(kind: "review")
        await fx.vm.openExplain(review)
        XCTAssertFalse(fx.vm.isExplaining(review.id))
        XCTAssertTrue(fx.tower.calls(.chatNew).isEmpty)
    }
}

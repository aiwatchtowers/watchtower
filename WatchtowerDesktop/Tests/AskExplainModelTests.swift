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

        let answer = try OwnerAskAnswer(note: "Yes").encoded()
        try await fx.pool.write { db in
            try db.execute(sql: "UPDATE owner_asks SET status = 'answered', answer = ? WHERE id = ?",
                           arguments: [answer, ask.id])
        }
        await fx.vm.load(projectID: fx.projectID)
        XCTAssertNil(fx.vm.loadErrors[fx.projectID])
        XCTAssertEqual(fx.vm.drawerAsk(projectID: fx.projectID)?.status, .answered, "the reload saw the closed ask")
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

    /// A stored reply cut by an exhausted quota never offers Retry (no-replay).
    func testQuotaPartialOffersNoRetry() async throws {
        let ask = try fx.insertAsk()
        let conversationID = try await AskExplainSurface.conversationID(ask: ask, dbPool: fx.pool, writes: fx.writes)
        try await fx.pool.write { db in
            let id = try TestDatabase.insertChatMessage(db, conversationID: conversationID, role: "assistant",
                                                        text: "It decides", status: "partial")
            try db.execute(sql: "UPDATE chat_messages SET error_code = 'quota_exhausted' WHERE id = ?", arguments: [id])
        }
        await fx.vm.openExplain(ask)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask))
        XCTAssertFalse(engine.canRetry)
        XCTAssertTrue(fx.ai.calls.isEmpty)
    }

    /// The owner's follow-up failed and the app restarted: Retry re-sends
    /// that follow-up, not the explanation prompt.
    func testRetryAfterRestartResendsTheOwnerFollowUp() async throws {
        let ask = try fx.insertAsk()
        let conversationID = try await AskExplainSurface.conversationID(ask: ask, dbPool: fx.pool, writes: fx.writes)
        try await fx.pool.write { db in
            _ = try TestDatabase.insertChatMessage(db, conversationID: conversationID, role: "assistant", text: "Explained")
            _ = try TestDatabase.insertChatMessage(db, conversationID: conversationID, role: "user", text: "And option B?")
            _ = try TestDatabase.insertChatMessage(db, conversationID: conversationID, role: "assistant",
                                                   text: "", status: "error")
        }
        await fx.vm.openExplain(ask)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask))
        XCTAssertTrue(fx.ai.calls.isEmpty)
        XCTAssertTrue(engine.canRetry)
        engine.retry()
        await engine.started()
        let prompt = try XCTUnwrap(fx.ai.calls.first?.prompt)
        XCTAssertTrue(prompt.hasSuffix("And option B?"), prompt)
        XCTAssertFalse(prompt.hasSuffix(AskExplainPrompt.firstTurn))
    }

    /// The owner stopped the first explanation: reopening (the engine kept)
    /// offers no Retry and starts no turn.
    func testStoppedFirstTurnOffersNoRetry() async throws {
        let ask = try fx.insertAsk()
        await fx.vm.openExplain(ask)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask))
        await engine.started()
        fx.ai.emit(.text("It dec"))
        await waitForCondition { engine.liveTurn?.fullText == "It dec" }
        engine.stop()
        await waitForCondition { !engine.isBusy }
        await engine.finished()
        XCTAssertEqual(try fx.rows(try XCTUnwrap(engine.spec.key.conversationID)).last?.status, "partial")

        fx.vm.closeExplain(ask.id)
        await fx.vm.openExplain(ask)
        XCTAssertTrue(fx.vm.explainEngine(for: ask) === engine)
        XCTAssertFalse(engine.canRetry)
        XCTAssertEqual(fx.ai.calls.count, 1)
    }

    /// The center let the idle chat go: the read-only accessor makes nothing,
    /// `ensureExplainEngine` makes it again with the stored failure's Retry
    /// and sends nothing.
    func testEvictedEngineIsRebuiltWithTheRetryOffer() async throws {
        let ask = try fx.insertAsk()
        await fx.vm.openExplain(ask)
        let first = try XCTUnwrap(fx.vm.explainEngine(for: ask))
        await first.started()
        fx.ai.finish(throwing: WatchtowerAIError.exitCode(1, "claude crashed"))
        await waitForCondition { !first.isBusy }
        await first.finished()
        XCTAssertTrue(first.canRetry)

        fx.center.release(first.spec.key)
        XCTAssertNil(fx.vm.explainEngine(for: ask), "reading never rebuilds")
        let rebuilt = try XCTUnwrap(fx.vm.ensureExplainEngine(ask))
        XCTAssertFalse(rebuilt === first)
        XCTAssertTrue(fx.vm.explainEngine(for: ask) === rebuilt)
        XCTAssertTrue(rebuilt.canRetry, "the stored error offers Retry")
        XCTAssertFalse(rebuilt.isBusy)
        XCTAssertEqual(fx.ai.calls.count, 1, "nothing sent")
    }

    /// A deleted workbench is a gone context: no conversation, no turn.
    func testMissingWorkbenchOpensNothing() async throws {
        let ask = try fx.insertAsk()
        let projectID = fx.projectID
        try await fx.pool.write { db in
            try db.execute(sql: "DELETE FROM owner_asks WHERE project_id = ?", arguments: [projectID])
            try db.execute(sql: "DELETE FROM workbench_folders WHERE workbench_id = ?", arguments: [projectID])
            try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [projectID])
        }
        await fx.vm.openExplain(ask)
        XCTAssertEqual(fx.vm.explainErrors[ask.id], "This workbench no longer exists.")
        XCTAssertNil(fx.vm.explainEngine(for: ask))
        XCTAssertTrue(fx.tower.calls(.chatNew).isEmpty)
        XCTAssertTrue(fx.ai.calls.isEmpty)
    }

    /// A reopen hands the kept engine the surface read now: its prompt
    /// carries the target's new intent; nothing is sent.
    func testReopenRefreshesTheKeptEnginesPrompt() async throws {
        let projectID = fx.projectID
        let targetID = try await fx.pool.write { db in
            let id = try TestDatabase.insertWorkbenchTarget(db, projectID: projectID, text: "Feature")
            try db.execute(sql: "UPDATE targets SET intent = 'Old intent' WHERE id = ?", arguments: [id])
            return id
        }
        let ask = try fx.insertAsk(targetID: targetID)
        await fx.vm.openExplain(ask)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask))
        await finishTurn(engine)
        XCTAssertTrue(engine.spec.systemPrompt().contains("Old intent"))

        try await fx.pool.write { db in
            try db.execute(sql: "UPDATE targets SET intent = 'New intent' WHERE id = ?", arguments: [targetID])
        }
        fx.vm.closeExplain(ask.id)
        await fx.vm.openExplain(ask)
        XCTAssertTrue(fx.vm.explainEngine(for: ask) === engine, "the same engine and history")
        XCTAssertTrue(engine.spec.systemPrompt().contains("New intent"))
        XCTAssertFalse(engine.spec.systemPrompt().contains("Old intent"))
        XCTAssertFalse(engine.isBusy)
        XCTAssertEqual(fx.ai.calls.count, 1, "no turn on reopen")
    }

    /// The workbench went after the chat was opened once: the reopen says
    /// so, and the old chat is neither served nor made again.
    func testWorkbenchGoneAfterAnOpenDropsTheChat() async throws {
        let ask = try fx.insertAsk()
        await fx.vm.openExplain(ask)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask))
        await finishTurn(engine)
        fx.vm.closeExplain(ask.id)

        let projectID = fx.projectID
        try await fx.pool.write { db in
            try db.execute(sql: "DELETE FROM owner_asks WHERE project_id = ?", arguments: [projectID])
            try db.execute(sql: "DELETE FROM workbench_folders WHERE workbench_id = ?", arguments: [projectID])
            try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [projectID])
        }
        fx.center.release(engine.spec.key)
        await fx.vm.openExplain(ask)
        XCTAssertEqual(fx.vm.explainErrors[ask.id], "This workbench no longer exists.")
        XCTAssertNil(fx.vm.explainEngine(for: ask))
        XCTAssertNil(fx.vm.ensureExplainEngine(ask), "nothing is made again")
        XCTAssertNil(fx.center.loaded(engine.spec.key))
        XCTAssertEqual(fx.ai.calls.count, 1)
    }

    /// Back closes the mode and forgets the ask's surface, error and
    /// rebuild count; the chat itself stays in the center (D5).
    func testCloseForgetsThePerAskState() async throws {
        let ask = try fx.insertAsk()
        await fx.vm.openExplain(ask)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask))
        await finishTurn(engine)
        fx.vm.closeExplain(ask.id)
        XCTAssertNil(fx.vm.explainEngine(for: ask), "the surface is forgotten")
        XCTAssertTrue(fx.center.loaded(engine.spec.key) === engine, "the chat is kept")
        await fx.vm.openExplain(ask)
        XCTAssertTrue(fx.vm.explainEngine(for: ask) === engine)
        XCTAssertEqual(fx.ai.calls.count, 1)
    }

    /// A failed open's error goes with Back.
    func testCloseClearsTheError() async throws {
        let ask = try fx.insertAsk()
        let projectID = fx.projectID
        try await fx.pool.write { db in
            try db.execute(sql: "DELETE FROM owner_asks WHERE project_id = ?", arguments: [projectID])
            try db.execute(sql: "DELETE FROM workbench_folders WHERE workbench_id = ?", arguments: [projectID])
            try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [projectID])
        }
        await fx.vm.openExplain(ask)
        XCTAssertNotNil(fx.vm.explainErrors[ask.id])
        fx.vm.closeExplain(ask.id)
        XCTAssertNil(fx.vm.explainErrors[ask.id])
    }

    /// Back pressed while the conversation was being found: the open's
    /// result is dropped — no surface kept, no engine made, no turn.
    func testOpenFinishingAfterCloseKeepsNothing() async throws {
        let ask = try fx.insertAsk()
        let held = TowerHold(fx.tower)
        let vm = fx.vm
        let open = Task { await vm.openExplain(ask) }
        let tower = fx.tower
        await waitForCondition { !tower.calls(.chatNew).isEmpty }
        vm.closeExplain(ask.id)
        held.release()
        await open.value
        XCTAssertFalse(vm.isExplaining(ask.id))
        XCTAssertNil(vm.explainEngine(for: ask))
        XCTAssertNil(vm.ensureExplainEngine(ask), "no surface kept for a closed ask")
        XCTAssertTrue(fx.ai.calls.isEmpty)
    }

    /// Multi-folder workbench: an ask filed from a session in a second
    /// folder reads that folder.
    func testAskFromSecondFolderReadsThatFolder() async throws {
        let projectID = fx.projectID
        let sessionID = try await fx.pool.write { db -> Int64 in
            let folderID = try Self.insertFolder(db, projectID: projectID, path: "/tmp/acme-explain-api")
            return try Self.insertSession(db, projectID: projectID, folderID: folderID)
        }
        let ask = try fx.insertAsk(sessionID: sessionID)
        await fx.vm.openExplain(ask)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask))
        await engine.started()
        XCTAssertEqual(fx.ai.calls.first?.readFolder, "/tmp/acme-explain-api")
    }

    /// The session's folder is not a live folder of this bench (removed, or
    /// another bench's): the home folder.
    func testFolderOffTheBenchFallsBackToHome() async throws {
        let projectID = fx.projectID
        let sessions = try await fx.pool.write { db -> [Int64] in
            let removed = try Self.insertFolder(db, projectID: projectID, path: "/tmp/acme-explain-old")
            try db.execute(sql: "UPDATE workbench_folders SET removed_at = '2026-11-24T00:00:00Z' WHERE id = ?",
                           arguments: [removed])
            let other = try TestDatabase.insertWorkbench(db, name: "other", folder: "/tmp/acme-explain-other")
            let otherFolder = try XCTUnwrap(try WorkbenchFolderQueries.homeFolderID(db, workbenchID: other))
            return [try Self.insertSession(db, projectID: projectID, folderID: removed),
                    try Self.insertSession(db, projectID: projectID, folderID: otherFolder)]
        }
        for sessionID in sessions {
            let ask = try fx.insertAsk(sessionID: sessionID)
            let folder = try await fx.pool.read {
                try AskExplainSurface.readFolder($0, ask: ask, homeFolder: "/tmp/acme-explain")
            }
            XCTAssertEqual(folder, "/tmp/acme-explain", "session \(sessionID)")
        }
    }

    nonisolated private static func insertFolder(_ db: Database, projectID: Int64, path: String) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO workbench_folders (workbench_id, folder_path, position, added_by, name)
            VALUES (?, ?, (SELECT COUNT(*) FROM workbench_folders WHERE workbench_id = ?), 'owner', ?)
            """, arguments: [projectID, path, projectID, (path as NSString).lastPathComponent])
        return db.lastInsertedRowID
    }

    nonisolated private static func insertSession(_ db: Database, projectID: Int64, folderID: Int64) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO terminal_sessions (project_id, kind, title, folder_path, workbench_folder_id)
            VALUES (?, 'shell', 'API work', '/tmp', ?)
            """, arguments: [projectID, folderID])
        return db.lastInsertedRowID
    }

    func testReviewAskOpensNoChat() async throws {
        let review = try fx.insertAsk(kind: "review")
        await fx.vm.openExplain(review)
        XCTAssertFalse(fx.vm.isExplaining(review.id))
        XCTAssertTrue(fx.tower.calls(.chatNew).isEmpty)
    }
}

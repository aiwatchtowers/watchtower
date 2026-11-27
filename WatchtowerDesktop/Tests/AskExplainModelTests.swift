import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The "Not clear?" mode of `OwnerAsksViewModel` — per ask, one item at a
/// time, every other state per item (specs 2026-11-24 "The chat view", "The
/// first message", "Failure paths"; 2026-11-27 "The mode and the state",
/// D4, "Failure paths").
@MainActor
final class AskExplainModelTests: XCTestCase {
    private var fx: AskExplainFixture!

    override func setUpWithError() throws {
        fx = try AskExplainFixture()
    }

    override func tearDown() {
        fx.cleanup()
    }

    private let q1 = AskExplainItem.question(1)

    private func subject(_ ask: OwnerAsk, _ item: AskExplainItem = .question(1)) -> AskExplainSubject {
        AskExplainSubject(askID: ask.id, item: item)
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
        await fx.vm.openExplain(ask, item: q1)
        XCTAssertTrue(fx.vm.isExplaining(ask.id))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: q1))
        await engine.started()
        XCTAssertEqual(fx.ai.calls.count, 1)
        let call = try XCTUnwrap(fx.ai.calls.first)
        XCTAssertEqual(call.prompt, AskExplainPrompt.firstTurn(q1))
        XCTAssertNil(call.persist?.ownerText, "hidden: no owner row")
        XCTAssertEqual(call.purpose, AskExplainKey.purpose)
        XCTAssertEqual(call.readFolder, "/tmp/acme-explain")
        XCTAssertNil(call.toolMode, "draft-only")
        await finishTurn(engine)

        fx.vm.closeExplain(ask.id)
        XCTAssertFalse(fx.vm.isExplaining(ask.id))
        await fx.vm.openExplain(ask, item: q1)
        XCTAssertTrue(fx.vm.isExplaining(ask.id))
        XCTAssertEqual(fx.ai.calls.count, 1, "a chat with messages starts nothing")
    }

    func testOpenAnItemTwiceStartsOneHiddenTurn() async throws {
        let check = try fx.insertAsk(kind: "check")
        async let first: Void = fx.vm.openExplain(check, item: .step(1))
        async let second: Void = fx.vm.openExplain(check, item: .step(1))
        _ = await (first, second)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: check, item: .step(1)))
        await engine.started()
        XCTAssertEqual(fx.hiddenTurns.count, 1)
        XCTAssertEqual(fx.hiddenTurns(.step(1)).count, 1)
        XCTAssertEqual(fx.tower.calls(.chatNew).count, 1)
    }

    func testPartialFirstTurnOffersRetryOnly() async throws {
        let ask = try fx.insertAsk()
        let conversationID = try await fx.conversation(ask)
        try await fx.pool.write { db in
            _ = try TestDatabase.insertChatMessage(db, conversationID: conversationID, role: "assistant",
                                                   text: "It decides", status: "partial")
        }
        await fx.vm.openExplain(ask, item: q1)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: q1))
        XCTAssertTrue(fx.ai.calls.isEmpty, "no second hidden turn on its own")
        XCTAssertFalse(engine.isBusy)
        XCTAssertTrue(engine.canRetry, "the partial reply offers Retry")

        engine.retry()
        await engine.started()
        XCTAssertEqual(fx.ai.calls.count, 1)
        XCTAssertTrue(fx.ai.calls[0].prompt.hasSuffix(AskExplainPrompt.firstTurn(q1)), "Retry reruns the hidden prompt")
        XCTAssertNil(fx.ai.calls[0].persist?.ownerText)
    }

    func testErrorRow() async throws {
        let ask = try fx.insertAsk()
        await fx.vm.openExplain(ask, item: q1)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: q1))
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

    /// Spec D10: the mode is per ask and holds one item; another ask's mode
    /// is its own; the drawer going forgets both.
    func testModeHoldsOneItemPerAsk() async throws {
        let first = try fx.insertAsk(title: "A")
        let second = try fx.insertAsk(title: "B")
        fx.vm.openDrawer(first)
        await fx.vm.openExplain(first, item: .question(2))
        XCTAssertEqual(fx.vm.explainItem(first.id), .question(2))
        XCTAssertTrue(fx.vm.isExplaining(first.id))
        fx.vm.openDrawer(second)
        XCTAssertFalse(fx.vm.isExplaining(second.id))
        XCTAssertNil(fx.vm.explainItem(second.id))
        await fx.vm.openExplain(second, item: .question(1))
        XCTAssertEqual(fx.vm.explainItem(second.id), .question(1))

        fx.vm.closeExplain(first.id)
        XCTAssertFalse(fx.vm.isExplaining(first.id))
        XCTAssertNil(fx.vm.explainItem(first.id))
        await fx.vm.openExplain(first, item: .question(3))
        XCTAssertEqual(fx.vm.explainItem(first.id), .question(3))
        XCTAssertEqual(fx.vm.explainItem(second.id), .question(1), "another ask's mode is untouched")

        fx.vm.hideDrawer(projectID: fx.projectID)
        XCTAssertFalse(fx.vm.isExplaining(first.id))
        XCTAssertFalse(fx.vm.isExplaining(second.id))
        XCTAssertTrue(fx.vm.explainOpen.isEmpty)
    }

    func testItemChatSurvivesAskClosing() async throws {
        let ask = try fx.insertAsk()
        fx.vm.openDrawer(ask)
        await fx.vm.load(projectID: fx.projectID)
        await fx.vm.openExplain(ask, item: .question(2))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(2)))
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
        XCTAssertTrue(fx.vm.explainEngine(for: ask, item: .question(2)) === engine)
        XCTAssertTrue(engine.isBusy, "the running turn is untouched")
        XCTAssertEqual(fx.ai.calls.count, 1)
    }

    func testNoCLINoItemChat() async throws {
        let ask = try fx.insertAsk()
        fx.vm.chats = nil
        await fx.vm.openExplain(ask, item: q1)
        XCTAssertFalse(fx.vm.isExplaining(ask.id))
        XCTAssertNil(fx.vm.explainEngine(for: ask, item: q1))
        XCTAssertTrue(fx.tower.calls(.chatNew).isEmpty)
        XCTAssertTrue(fx.ai.calls.isEmpty)
    }

    /// A stored reply cut by an exhausted quota never offers Retry (no-replay).
    func testQuotaPartialOffersNoRetry() async throws {
        let ask = try fx.insertAsk()
        let conversationID = try await fx.conversation(ask)
        try await fx.pool.write { db in
            let id = try TestDatabase.insertChatMessage(db, conversationID: conversationID, role: "assistant",
                                                        text: "It decides", status: "partial")
            try db.execute(sql: "UPDATE chat_messages SET error_code = 'quota_exhausted' WHERE id = ?", arguments: [id])
        }
        await fx.vm.openExplain(ask, item: q1)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: q1))
        XCTAssertFalse(engine.canRetry)
        XCTAssertTrue(fx.ai.calls.isEmpty)
    }

    /// The owner's follow-up failed and the app restarted: Retry re-sends
    /// that follow-up, not the explanation prompt.
    func testRetryAfterRestartResendsTheOwnerFollowUp() async throws {
        let ask = try fx.insertAsk()
        let conversationID = try await fx.conversation(ask)
        try await fx.pool.write { db in
            _ = try TestDatabase.insertChatMessage(db, conversationID: conversationID, role: "assistant", text: "Explained")
            _ = try TestDatabase.insertChatMessage(db, conversationID: conversationID, role: "user", text: "And option B?")
            _ = try TestDatabase.insertChatMessage(db, conversationID: conversationID, role: "assistant",
                                                   text: "", status: "error")
        }
        await fx.vm.openExplain(ask, item: q1)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: q1))
        XCTAssertTrue(fx.ai.calls.isEmpty)
        XCTAssertTrue(engine.canRetry)
        engine.retry()
        await engine.started()
        let prompt = try XCTUnwrap(fx.ai.calls.first?.prompt)
        XCTAssertTrue(prompt.hasSuffix("And option B?"), prompt)
        XCTAssertFalse(prompt.hasSuffix(AskExplainPrompt.firstTurn(q1)))
    }

    /// The owner stopped the first explanation: reopening (the engine kept)
    /// offers no Retry and starts no turn.
    func testStoppedFirstTurnOffersNoRetry() async throws {
        let ask = try fx.insertAsk()
        await fx.vm.openExplain(ask, item: q1)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: q1))
        await engine.started()
        fx.ai.emit(.text("It dec"))
        await waitForCondition { engine.liveTurn?.fullText == "It dec" }
        engine.stop()
        await waitForCondition { !engine.isBusy }
        await engine.finished()
        XCTAssertEqual(try fx.rows(try XCTUnwrap(engine.spec.key.conversationID)).last?.status, "partial")

        fx.vm.closeExplain(ask.id)
        await fx.vm.openExplain(ask, item: q1)
        XCTAssertTrue(fx.vm.explainEngine(for: ask, item: q1) === engine)
        XCTAssertFalse(engine.canRetry)
        XCTAssertEqual(fx.ai.calls.count, 1)
    }

    /// The center let the idle chat go: the read-only accessor makes nothing,
    /// `ensureExplainEngine` makes it again with the stored failure's Retry
    /// and sends nothing.
    func testEvictedEngineIsRebuiltWithTheRetryOffer() async throws {
        let ask = try fx.insertAsk()
        await fx.vm.openExplain(ask, item: q1)
        let first = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: q1))
        await first.started()
        fx.ai.finish(throwing: WatchtowerAIError.exitCode(1, "claude crashed"))
        await waitForCondition { !first.isBusy }
        await first.finished()
        XCTAssertTrue(first.canRetry)

        fx.center.release(first.spec.key)
        XCTAssertNil(fx.vm.explainEngine(for: ask, item: q1), "reading never rebuilds")
        let rebuilt = try XCTUnwrap(fx.vm.ensureExplainEngine(ask, item: q1))
        XCTAssertFalse(rebuilt === first)
        XCTAssertTrue(fx.vm.explainEngine(for: ask, item: q1) === rebuilt)
        XCTAssertTrue(rebuilt.canRetry, "the stored error offers Retry")
        XCTAssertFalse(rebuilt.isBusy)
        XCTAssertEqual(fx.ai.calls.count, 1, "nothing sent")
    }

    /// A deleted workbench is a gone context: no conversation, no turn.
    func testMissingWorkbenchOpensNoItemChat() async throws {
        let ask = try fx.insertAsk()
        try fx.dropWorkbenchRows()
        await fx.vm.openExplain(ask, item: q1)
        XCTAssertEqual(fx.vm.explainErrors[subject(ask)], "This workbench no longer exists.")
        XCTAssertNil(fx.vm.explainEngine(for: ask, item: q1))
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
        await fx.vm.openExplain(ask, item: q1)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: q1))
        await finishTurn(engine)
        XCTAssertTrue(engine.spec.systemPrompt().contains("Old intent"))

        try await fx.pool.write { db in
            try db.execute(sql: "UPDATE targets SET intent = 'New intent' WHERE id = ?", arguments: [targetID])
        }
        fx.vm.closeExplain(ask.id)
        await fx.vm.openExplain(ask, item: q1)
        XCTAssertTrue(fx.vm.explainEngine(for: ask, item: q1) === engine, "the same engine and history")
        XCTAssertTrue(engine.spec.systemPrompt().contains("New intent"))
        XCTAssertFalse(engine.spec.systemPrompt().contains("Old intent"))
        XCTAssertFalse(engine.isBusy)
        XCTAssertEqual(fx.ai.calls.count, 1, "no turn on reopen")
    }

    /// The workbench went after the chat was opened once: the reopen says
    /// so, and the old chat is neither served nor made again.
    func testWorkbenchGoneAfterAnOpenDropsTheChat() async throws {
        let ask = try fx.insertAsk()
        await fx.vm.openExplain(ask, item: q1)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: q1))
        await finishTurn(engine)
        fx.vm.closeExplain(ask.id)

        try fx.dropWorkbenchRows()
        fx.center.release(engine.spec.key)
        await fx.vm.openExplain(ask, item: q1)
        XCTAssertEqual(fx.vm.explainErrors[subject(ask)], "This workbench no longer exists.")
        XCTAssertNil(fx.vm.explainEngine(for: ask, item: q1))
        XCTAssertNil(fx.vm.ensureExplainEngine(ask, item: q1), "nothing is made again")
        XCTAssertNil(fx.center.loaded(engine.spec.key))
        XCTAssertEqual(fx.ai.calls.count, 1)
    }

    /// Back closes the mode and forgets the ask's surface, error and
    /// rebuild count; the chat itself stays in the center (D5).
    func testCloseForgetsThePerAskState() async throws {
        let ask = try fx.insertAsk()
        await fx.vm.openExplain(ask, item: q1)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: q1))
        await finishTurn(engine)
        fx.vm.closeExplain(ask.id)
        XCTAssertNil(fx.vm.explainEngine(for: ask, item: q1), "the surface is forgotten")
        XCTAssertTrue(fx.center.loaded(engine.spec.key) === engine, "the chat is kept")
        await fx.vm.openExplain(ask, item: q1)
        XCTAssertTrue(fx.vm.explainEngine(for: ask, item: q1) === engine)
        XCTAssertEqual(fx.ai.calls.count, 1)
    }

    /// A failed open's error goes with Back.
    /// After a failed open of q1, Back forgets that item's error, final
    /// flag and surface; its chat stays in the center.
    func testCloseForgetsTheItemsState() async throws {
        let ask = try fx.insertAsk()
        await fx.vm.openExplain(ask, item: q1)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: q1))
        await finishTurn(engine)
        fx.vm.closeExplain(ask.id)
        try fx.dropWorkbenchRows()
        await fx.vm.openExplain(ask, item: q1)
        XCTAssertNotNil(fx.vm.explainErrors[subject(ask)])
        XCTAssertTrue(fx.vm.explainFinal.contains(subject(ask)))

        fx.vm.closeExplain(ask.id)
        XCTAssertNil(fx.vm.explainErrors[subject(ask)])
        XCTAssertTrue(fx.vm.explainFinal.isEmpty)
        XCTAssertNil(fx.vm.explainEngine(for: ask, item: q1), "the surface is forgotten")
        XCTAssertNil(fx.vm.ensureExplainEngine(ask, item: q1))
        XCTAssertTrue(fx.center.loaded(engine.spec.key) === engine, "the chat is kept")
    }

    /// Back pressed while the conversation was being found: the open's
    /// result is dropped — no surface kept, no engine made, no turn.
    func testOpenFinishingAfterCloseKeepsNothing() async throws {
        let ask = try fx.insertAsk()
        let held = TowerHold(fx.tower)
        let vm = fx.vm
        let open = Task { await vm.openExplain(ask, item: q1) }
        let tower = fx.tower
        await waitForCondition { !tower.calls(.chatNew).isEmpty }
        vm.closeExplain(ask.id)
        held.release()
        await open.value
        XCTAssertFalse(vm.isExplaining(ask.id))
        XCTAssertNil(vm.explainEngine(for: ask, item: q1))
        XCTAssertNil(vm.ensureExplainEngine(ask, item: q1), "no surface kept for a closed ask")
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
        await fx.vm.openExplain(ask, item: q1)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: q1))
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

    /// A session being deleted (PROJ-17) counts as gone: its live second
    /// folder is not read, the home folder is.
    func testDeletingSessionFallsBackToHome() async throws {
        let projectID = fx.projectID
        let sessionID = try await fx.pool.write { db -> Int64 in
            let folderID = try Self.insertFolder(db, projectID: projectID, path: "/tmp/acme-explain-api")
            let id = try Self.insertSession(db, projectID: projectID, folderID: folderID)
            try db.execute(sql: "UPDATE terminal_sessions SET delete_requested_at = '2026-11-24T00:00:00Z' WHERE id = ?",
                           arguments: [id])
            return id
        }
        let ask = try fx.insertAsk(sessionID: sessionID)
        let folder = try await fx.pool.read {
            try AskExplainSurface.readFolder($0, ask: ask, homeFolder: "/tmp/acme-explain")
        }
        XCTAssertEqual(folder, "/tmp/acme-explain")
    }

    // MARK: - Races (board #2383, ask #1849)

    /// A merge while the explanation streams: the next open finds the
    /// running engine under the old key and moves it to the new one — one
    /// engine for the chat, the turn untouched, no second hidden turn.
    func testMergeMidStreamMovesTheRunningItemEngine() async throws {
        let ask = try fx.insertAsk()
        await fx.vm.openExplain(ask, item: .question(2))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(2)))
        await engine.started()
        let oldKey = engine.spec.key
        let conversationID = try XCTUnwrap(oldKey.conversationID)

        // What `reKeyChats` and the merge write: the ask and its chat move.
        let into = try await fx.pool.write { db -> Int64 in
            let into = try TestDatabase.insertWorkbench(db, name: "beta", folder: "/tmp/acme-explain-beta")
            try db.execute(sql: "UPDATE owner_asks SET project_id = ? WHERE id = ?", arguments: [into, ask.id])
            try db.execute(sql: "UPDATE chat_conversations SET context_id = ? WHERE id = ?",
                           arguments: [AskExplainKey.contextID(workbenchID: into, askID: ask.id, item: .question(2)), conversationID])
            return into
        }
        let stored = try await fx.pool.read { try OwnerAskQueries.ask($0, id: ask.id, projectID: into) }
        let moved = try XCTUnwrap(stored)
        fx.vm.closeExplain(ask.id)
        await fx.vm.openExplain(moved, item: .question(2))

        XCTAssertTrue(fx.vm.explainEngine(for: moved, item: .question(2)) === engine, "the running engine, not a second one")
        XCTAssertEqual(fx.center.count, 1)
        XCTAssertNil(fx.center.loaded(oldKey))
        XCTAssertEqual(engine.spec.key.contextID, AskExplainKey.contextID(workbenchID: into, askID: ask.id, item: .question(2)))
        XCTAssertEqual(engine.spec.key.conversationID, conversationID)
        XCTAssertTrue(engine.isBusy, "the turn runs on")
        await finishTurn(engine)
        XCTAssertEqual(try fx.rows(conversationID).last?.status, "complete")
        XCTAssertEqual(fx.hiddenTurns.count, 1)
    }

    /// The workbench is deleted between the open's read and its `chat.new`:
    /// the create is refused (Go checks the bench in its transaction), no
    /// conversation is left, and the failure is final — no Retry.
    func testWorkbenchDeletedBeforeItemChatNewLeavesNoChat() async throws {
        let ask = try fx.insertAsk()
        let held = TowerHold(fx.tower)
        let vm = fx.vm
        let open = Task { await vm.openExplain(ask, item: q1) }
        let tower = fx.tower
        await waitForCondition { !tower.calls(.chatNew).isEmpty }
        try fx.dropWorkbenchRows()
        held.release()
        await open.value

        XCTAssertEqual(vm.explainErrors[subject(ask)], "This workbench no longer exists.")
        XCTAssertFalse(vm.explainOffersRetry(subject(ask)), "Retry would fail the same way")
        XCTAssertNil(vm.explainEngine(for: ask, item: q1))
        let chats = try await fx.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_conversations WHERE context_type = ?",
                             arguments: [AskExplainKey.contextType])
        }
        XCTAssertEqual(chats, 0, "no orphan conversation")
        XCTAssertTrue(fx.ai.calls.isEmpty)
    }

    /// A failed open Retry can mend (any other refusal) keeps its Retry;
    /// Back forgets the final state.
    func testOnlyAGoneWorkbenchTakesTheRetryAway() async throws {
        let ask = try fx.insertAsk()
        fx.tower.refuse(.chatNew, with: "The database is busy.")
        await fx.vm.openExplain(ask, item: q1)
        XCTAssertNotNil(fx.vm.explainErrors[subject(ask)])
        XCTAssertTrue(fx.vm.explainOffersRetry(subject(ask)))

        fx.tower.refuse(.chatNew, with: nil)
        try fx.dropWorkbenchRows()
        await fx.vm.openExplain(ask, item: q1)
        XCTAssertFalse(fx.vm.explainOffersRetry(subject(ask)))
        fx.vm.closeExplain(ask.id)
        XCTAssertTrue(fx.vm.explainOffersRetry(subject(ask)))
    }

    /// Back, then a reopen before `chat.new` answered: one conversation, one
    /// hidden turn, and the surface the reopen read (the target's new intent).
    func testBackAndReopenAnItemBeforeChatNewMakesOneChatWithTheLatestRead() async throws {
        let projectID = fx.projectID
        let targetID = try await fx.pool.write { db in
            let id = try TestDatabase.insertWorkbenchTarget(db, projectID: projectID, text: "Feature")
            try db.execute(sql: "UPDATE targets SET intent = 'Old intent' WHERE id = ?", arguments: [id])
            return id
        }
        let ask = try fx.insertAsk(targetID: targetID)
        let held = TowerHold(fx.tower)
        let vm = fx.vm
        let first = Task { await vm.openExplain(ask, item: q1) }
        let tower = fx.tower
        await waitForCondition { !tower.calls(.chatNew).isEmpty }
        vm.closeExplain(ask.id)
        try await fx.pool.write { db in
            try db.execute(sql: "UPDATE targets SET intent = 'New intent' WHERE id = ?", arguments: [targetID])
        }
        await vm.openExplain(ask, item: q1)
        held.release()
        await first.value

        XCTAssertTrue(vm.isExplaining(ask.id))
        let engine = try XCTUnwrap(vm.explainEngine(for: ask, item: q1))
        await engine.started()
        XCTAssertEqual(fx.hiddenTurns.count, 1, "one hidden first turn")
        XCTAssertEqual(fx.center.count, 1)
        let chats = try await fx.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_conversations WHERE context_type = ?",
                             arguments: [AskExplainKey.contextType])
        }
        XCTAssertEqual(chats, 1, "one conversation")
        XCTAssertTrue(engine.spec.systemPrompt().contains("New intent"), "the reopen's read wins")
        await finishTurn(engine)
    }

    /// A session in its delete's 5-second Undo window (not written yet) is
    /// gone for the folder: the home folder is read. Undo brings it back,
    /// and the next open reads its folder again.
    func testSessionInTheUndoWindowIsGoneUntilUndo() async throws {
        let projectID = fx.projectID
        let sessionID = try await fx.pool.write { db -> Int64 in
            let folderID = try Self.insertFolder(db, projectID: projectID, path: "/tmp/acme-explain-api")
            return try Self.insertSession(db, projectID: projectID, folderID: folderID)
        }
        let ask = try fx.insertAsk(sessionID: sessionID)
        var hidden: Set<Int64> = [sessionID]
        fx.vm.hiddenSessions = { hidden }
        await fx.vm.openExplain(ask, item: q1)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: q1))
        await engine.started()
        XCTAssertEqual(fx.ai.calls.first?.readFolder, "/tmp/acme-explain", "the deleted session's folder is not read")
        await finishTurn(engine)

        hidden = []  // Undo
        fx.vm.closeExplain(ask.id)
        await fx.vm.openExplain(ask, item: q1)
        XCTAssertTrue(fx.vm.explainEngine(for: ask, item: q1) === engine)
        XCTAssertEqual(engine.spec.runOptions().readFolder, "/tmp/acme-explain-api", "back after Undo")
        XCTAssertEqual(fx.ai.calls.count, 1)
    }

    /// The owner stopped the explanation, then the engine was made again
    /// (the center let it go, or the app restarted): still no Retry — the
    /// stop is remembered, though Stop and quit store the same `partial`.
    func testStoppedItemFirstTurnOffersNoRetryAfterARebuild() async throws {
        let ask = try fx.insertAsk(kind: "check")
        await fx.vm.openExplain(ask, item: .step(2))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .step(2)))
        await engine.started()
        fx.ai.emit(.text("It dec"))
        await waitForCondition { engine.liveTurn?.fullText == "It dec" }
        engine.stop()
        await waitForCondition { !engine.isBusy }
        await engine.finished()
        XCTAssertEqual(try fx.rows(try XCTUnwrap(engine.spec.key.conversationID)).last?.status, "partial")

        fx.center.release(engine.spec.key)
        let rebuilt = try XCTUnwrap(fx.vm.ensureExplainEngine(ask, item: .step(2)))
        XCTAssertFalse(rebuilt === engine)
        XCTAssertFalse(rebuilt.canRetry, "a stopped explanation offers no Retry")

        // A restart: a new view model over the same preferences.
        fx.center.release(rebuilt.spec.key)
        let restarted = OwnerAsksViewModel(dbPool: fx.pool, terminalCenter: nil,
                                           lineDelivery: SessionLineDelivery(terminalCenter: nil), defaults: fx.defaults)
        restarted.chats = fx.center
        restarted.chatWrites = fx.writes
        restarted.explainCatalog = fx.catalog
        restarted.explainConfigProvider = { "claude" }
        await restarted.openExplain(ask, item: .step(2))
        let reopened = try XCTUnwrap(restarted.explainEngine(for: ask, item: .step(2)))
        XCTAssertFalse(reopened.canRetry)
        XCTAssertEqual(fx.ai.calls.count, 1)
    }

    /// Two workspaces' databases share one preferences suite: a stop in one
    /// never takes the Retry from a quit reply in the other, though both
    /// replies have the same row ids (the marker is the turn's UUID).
    func testAStopInOneDatabaseKeepsRetryInAnother() async throws {
        let ask = try fx.insertAsk()
        await fx.vm.openExplain(ask, item: q1)
        let stopped = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: q1))
        await stopped.started()
        fx.ai.emit(.text("It dec"))
        await waitForCondition { stopped.liveTurn?.fullText == "It dec" }
        stopped.stop()
        await waitForCondition { !stopped.isBusy }
        await stopped.finished()

        let other = try AskExplainFixture(defaults: fx.defaults)
        defer { other.cleanup() }
        let otherAsk = try other.insertAsk()
        XCTAssertEqual(otherAsk.id, ask.id, "the same ids in a second database")
        await other.vm.openExplain(otherAsk, item: q1)
        let quit = try XCTUnwrap(other.vm.explainEngine(for: otherAsk, item: q1))
        await quit.started()
        other.ai.emit(.text("It dec"))
        await waitForCondition { quit.liveTurn?.fullText == "It dec" }
        other.center.finishAllAsPartial()
        await waitForCondition { !quit.isBusy }
        await quit.finished()
        XCTAssertEqual(quit.messages.last?.id, stopped.messages.last?.id, "the same reply row id")

        other.center.release(quit.spec.key)
        let rebuilt = try XCTUnwrap(other.vm.ensureExplainEngine(otherAsk, item: q1))
        XCTAssertTrue(rebuilt.canRetry, "the other database's quit reply still offers Retry")
    }

    /// Stop pressed while the first turn's rows are still being written:
    /// the turn ends stopped once they land, and a rebuilt engine offers no
    /// Retry for it.
    func testStopBeforeTheTurnStartedOffersNoRetryAfterARebuild() async throws {
        let ask = try fx.insertAsk()
        fx.ai.holdPersistStart()
        await fx.vm.openExplain(ask, item: q1)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: q1))
        XCTAssertTrue(engine.isStarting)
        engine.stop()
        fx.ai.releasePersistStart()
        await waitForCondition { !engine.isBusy }
        await engine.finished()
        XCTAssertEqual(try fx.rows(try XCTUnwrap(engine.spec.key.conversationID)).last?.status, "partial")

        fx.center.release(engine.spec.key)
        let rebuilt = try XCTUnwrap(fx.vm.ensureExplainEngine(ask, item: q1))
        XCTAssertFalse(rebuilt.canRetry, "the owner's Stop before the start is remembered too")
    }

    /// The app quit mid-explanation: the rebuilt engine offers Retry.
    func testQuitFirstTurnOffersRetryAfterARebuild() async throws {
        let ask = try fx.insertAsk()
        await fx.vm.openExplain(ask, item: q1)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: q1))
        await engine.started()
        fx.ai.emit(.text("It dec"))
        await waitForCondition { engine.liveTurn?.fullText == "It dec" }
        fx.center.finishAllAsPartial()
        await waitForCondition { !engine.isBusy }
        await engine.finished()
        XCTAssertEqual(try fx.rows(try XCTUnwrap(engine.spec.key.conversationID)).last?.status, "partial")

        fx.center.release(engine.spec.key)
        let rebuilt = try XCTUnwrap(fx.vm.ensureExplainEngine(ask, item: q1))
        XCTAssertTrue(rebuilt.canRetry, "a quit-partial explanation offers Retry")
        XCTAssertEqual(fx.ai.calls.count, 1)
    }

    // MARK: - Items (spec 2026-11-27)

    /// Each item has its own chat with its own first turn; reopening one
    /// starts nothing (D3).
    func testEachItemHasItsOwnChat() async throws {
        let ask = try fx.insertAsk()
        await fx.vm.openExplain(ask, item: .question(1))
        let first = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(1)))
        await finishTurn(first)
        XCTAssertEqual(fx.hiddenTurns(.question(1)).count, 1)
        fx.vm.closeExplain(ask.id)

        await fx.vm.openExplain(ask, item: .question(2))
        let second = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(2)))
        XCTAssertFalse(first === second)
        await finishTurn(second)
        XCTAssertEqual(fx.hiddenTurns(.question(2)).count, 1)
        fx.vm.closeExplain(ask.id)

        await fx.vm.openExplain(ask, item: .question(1))
        XCTAssertTrue(fx.vm.explainEngine(for: ask, item: .question(1)) === first)
        XCTAssertEqual(fx.ai.calls.count, 2, "no third turn")
        XCTAssertEqual(fx.center.count, 2)
        XCTAssertNotEqual(first.spec.key.conversationID, second.spec.key.conversationID)
    }

    /// Review Focus 2: Back, then another item's entry, before the first
    /// open's `chat.new` answered — the first open writes nothing.
    func testBackAndOpenAnotherItemBeforeChatNewOpensOnlyTheSecond() async throws {
        let ask = try fx.insertAsk()
        let held = TowerHold(fx.tower)
        let (vm, tower) = (fx.vm, fx.tower)
        let first = Task { await vm.openExplain(ask, item: .question(1)) }
        await waitForCondition { tower.calls(.chatNew).count == 1 }
        vm.closeExplain(ask.id)
        let second = Task { await vm.openExplain(ask, item: .question(2)) }
        await waitForCondition { tower.calls(.chatNew).count == 2 }
        held.release()
        await first.value
        await second.value

        XCTAssertEqual(vm.explainItem(ask.id), .question(2))
        XCTAssertNil(vm.explainEngine(for: ask, item: .question(1)))
        XCTAssertNil(vm.ensureExplainEngine(ask, item: .question(1)), "no surface kept for the first item")
        let engine = try XCTUnwrap(vm.explainEngine(for: ask, item: .question(2)))
        await engine.started()
        XCTAssertTrue(fx.hiddenTurns(.question(1)).isEmpty)
        XCTAssertEqual(fx.hiddenTurns(.question(2)).count, 1)
        XCTAssertEqual(fx.center.count, 1)
    }

    /// Review Focus 3: q1's open is running when q1 is opened again (after a
    /// detour through q2): q1's open reads again for itself; q2's open,
    /// no longer shown, makes nothing.
    func testReopenOfOneItemIsNotAnotherItemsReopen() async throws {
        let projectID = fx.projectID
        let targetID = try await fx.pool.write { db in
            let id = try TestDatabase.insertWorkbenchTarget(db, projectID: projectID, text: "Feature")
            try db.execute(sql: "UPDATE targets SET intent = 'Old intent' WHERE id = ?", arguments: [id])
            return id
        }
        let ask = try fx.insertAsk(targetID: targetID)
        let held = TowerHold(fx.tower)
        let (vm, tower) = (fx.vm, fx.tower)
        let first = Task { await vm.openExplain(ask, item: .question(1)) }
        await waitForCondition { tower.calls(.chatNew).count == 1 }
        vm.closeExplain(ask.id)
        let second = Task { await vm.openExplain(ask, item: .question(2)) }
        await waitForCondition { tower.calls(.chatNew).count == 2 }
        vm.closeExplain(ask.id)
        try await fx.pool.write { db in
            try db.execute(sql: "UPDATE targets SET intent = 'New intent' WHERE id = ?", arguments: [targetID])
        }
        await vm.openExplain(ask, item: .question(1))
        held.release()
        await first.value
        await second.value

        XCTAssertEqual(vm.explainItem(ask.id), .question(1))
        XCTAssertNil(vm.explainEngine(for: ask, item: .question(2)), "q2's open, no longer shown, made nothing")
        XCTAssertNil(vm.ensureExplainEngine(ask, item: .question(2)))
        let engine = try XCTUnwrap(vm.explainEngine(for: ask, item: .question(1)))
        await engine.started()
        XCTAssertTrue(engine.spec.systemPrompt().contains("New intent"), "q1's open read again for its reopen")
        XCTAssertEqual(fx.hiddenTurns(.question(1)).count, 1)
        XCTAssertTrue(fx.hiddenTurns(.question(2)).isEmpty)
        XCTAssertEqual(fx.center.count, 1)
    }

    /// Back, then another item's entry, mid-turn of the first: it streams on
    /// in the center and finishes; the second starts its own turn.
    func testOpeningAnotherItemKeepsTheFirstStreaming() async throws {
        let ask = try fx.insertAsk()
        await fx.vm.openExplain(ask, item: .question(1))
        let first = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(1)))
        await first.started()
        fx.ai.emit(.text("It decides"), call: 0)
        await waitForCondition { first.liveTurn?.fullText == "It decides" }
        fx.vm.closeExplain(ask.id)

        await fx.vm.openExplain(ask, item: .question(2))
        let second = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(2)))
        await second.started()
        XCTAssertTrue(first.isBusy, "the first item's turn runs on")
        XCTAssertEqual(fx.hiddenTurns(.question(2)).count, 1)

        fx.ai.emit(.text(" the store."), .done, call: 0)
        fx.ai.finish(call: 0)
        await waitForCondition { !first.isBusy }
        await first.finished()
        let reply = try XCTUnwrap(try fx.rows(try XCTUnwrap(first.spec.key.conversationID)).last)
        XCTAssertEqual(reply.status, "complete")
        XCTAssertEqual(reply.text, "It decides the store.")
        XCTAssertTrue(second.isBusy)
        fx.ai.finish(call: 1)
        await waitForCondition { !second.isBusy }
        await second.finished()
    }

    /// Review Focus 4: Retry of an item's stored first turn re-sends that
    /// item's own first turn.
    func testRetryAfterRestartResendsTheItemsFirstTurn() async throws {
        let ask = try fx.insertAsk()
        let conversationID = try await fx.conversation(ask, .question(2))
        try await fx.pool.write { db in
            _ = try TestDatabase.insertChatMessage(db, conversationID: conversationID, role: "assistant",
                                                   text: "It decides", status: "partial")
        }
        await fx.vm.openExplain(ask, item: .question(2))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(2)))
        XCTAssertTrue(engine.canRetry)
        XCTAssertTrue(fx.ai.calls.isEmpty)
        engine.retry()
        await engine.started()
        let call = try XCTUnwrap(fx.ai.calls.first)
        XCTAssertTrue(call.prompt.hasSuffix(AskExplainPrompt.firstTurn(.question(2))), call.prompt)
        XCTAssertNil(call.persist?.ownerText, "hidden")
    }

    /// The stop markers are turn ids: q1's stop never takes q2's Retry.
    func testStopInOneItemKeepsRetryInAnother() async throws {
        let ask = try fx.insertAsk()
        await fx.vm.openExplain(ask, item: .question(1))
        let stopped = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(1)))
        await stopped.started()
        fx.ai.emit(.text("It dec"), call: 0)
        await waitForCondition { stopped.liveTurn?.fullText == "It dec" }
        stopped.stop()
        await waitForCondition { !stopped.isBusy }
        await stopped.finished()
        fx.vm.closeExplain(ask.id)

        await fx.vm.openExplain(ask, item: .question(2))
        let quit = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(2)))
        await quit.started()
        fx.ai.emit(.text("It dec"), call: 1)
        await waitForCondition { quit.liveTurn?.fullText == "It dec" }
        fx.center.finishAllAsPartial()
        await waitForCondition { !quit.isBusy }
        await quit.finished()
        fx.vm.closeExplain(ask.id)

        fx.center.release(stopped.spec.key)
        fx.center.release(quit.spec.key)
        await fx.vm.openExplain(ask, item: .question(1))
        let rebuiltStopped = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(1)))
        XCTAssertFalse(rebuiltStopped === stopped)
        XCTAssertFalse(rebuiltStopped.canRetry, "q1 was stopped")
        fx.vm.closeExplain(ask.id)
        await fx.vm.openExplain(ask, item: .question(2))
        let rebuiltQuit = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(2)))
        XCTAssertTrue(rebuiltQuit.canRetry, "q2 was cut by the quit")
        XCTAssertEqual(fx.ai.calls.count, 2)
    }

    /// A crash between `chat.new` and the first turn left the item's chat
    /// empty: the next open starts the explanation once.
    func testEmptyItemChatLeftByACrashStartsTheExplanation() async throws {
        let ask = try fx.insertAsk()
        let conversationID = try await fx.conversation(ask, .question(1))
        await fx.vm.openExplain(ask, item: .question(1))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(1)))
        await engine.started()
        XCTAssertEqual(engine.spec.key.conversationID, conversationID)
        XCTAssertEqual(fx.hiddenTurns.count, 1)
        XCTAssertEqual(fx.hiddenTurns(.question(1)).count, 1)
    }

    func testItemOutOfRangeOpensNothing() async throws {
        let ask = try fx.insertAsk()
        await fx.vm.openExplain(ask, item: .question(5))
        await fx.vm.openExplain(ask, item: .step(1))
        XCTAssertFalse(fx.vm.isExplaining(ask.id))
        XCTAssertNil(fx.vm.explainItem(ask.id))
        XCTAssertTrue(fx.tower.calls(.chatNew).isEmpty)
        XCTAssertTrue(fx.ai.calls.isEmpty)
    }

    // MARK: - Legacy whole-ask chats (spec D4)

    /// Review Focus 1: a 0.29.5 chat on a single-item ask is that item's
    /// chat — its key, its history, no `chat.new`, no hidden turn.
    func testLegacyWholeAskChatIsReusedOnASingleItemAsk() async throws {
        let question = try fx.insertAsk(payload: AskExplainFixture.oneQuestion)
        let check = try fx.insertAsk(kind: "check", payload: AskExplainFixture.oneStep)
        for (ask, item) in [(question, AskExplainItem.question(1)), (check, .step(1))] {
            let legacy = try fx.insertLegacyChat(ask, explanation: "It decides the store.")
            let before = try fx.conversationCount()
            await fx.vm.openExplain(ask, item: item)
            let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: item), "\(item)")
            XCTAssertEqual(engine.spec.key.conversationID, legacy)
            XCTAssertEqual(engine.spec.key.contextID, "\(fx.projectID):\(ask.id)")
            await waitForCondition { !engine.messages.isEmpty }
            XCTAssertEqual(engine.messages.map(\.message.text), ["It decides the store."])
            XCTAssertEqual(try fx.conversationCount(), before)
            fx.vm.closeExplain(ask.id)
        }
        XCTAssertTrue(fx.tower.calls(.chatNew).isEmpty, "no chat.new sent")
        XCTAssertTrue(fx.ai.calls.isEmpty, "no hidden turn")
    }

    /// On an ask with several items the legacy chat is not looked up: the
    /// item gets a new chat and the old row stays as it was.
    func testLegacyWholeAskChatIsNotReusedOnAMultiItemAsk() async throws {
        let ask = try fx.insertAsk()
        let legacy = try fx.insertLegacyChat(ask, explanation: "It decides the store.")
        await fx.vm.openExplain(ask, item: .question(1))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(1)))
        await engine.started()
        XCTAssertNotEqual(engine.spec.key.conversationID, legacy)
        XCTAssertEqual(engine.spec.key.contextID, "\(fx.projectID):\(ask.id):q1")
        XCTAssertEqual(fx.hiddenTurns.count, 1)
        XCTAssertEqual(try fx.conversationCount(), 2)
        XCTAssertEqual(try fx.rows(legacy).map(\.text), ["It decides the store."], "the legacy chat is untouched")
        let stored = try await fx.pool.read { try ChatConversationQueries.fetchByID($0, id: legacy) }
        XCTAssertEqual(stored?.contextID, "\(fx.projectID):\(ask.id)")
    }

    /// Two opens at once of a single-item ask share one chat, with a legacy
    /// row (both on it, no `chat.new`) and without (one new row, one turn).
    func testSingleItemOpenedTwiceUsesOneChat() async throws {
        let withLegacy = try fx.insertAsk(payload: AskExplainFixture.oneQuestion)
        let legacy = try fx.insertLegacyChat(withLegacy, explanation: "It decides the store.")
        async let one: Void = fx.vm.openExplain(withLegacy, item: .question(1))
        async let two: Void = fx.vm.openExplain(withLegacy, item: .question(1))
        _ = await (one, two)
        XCTAssertEqual(fx.vm.explainEngine(for: withLegacy, item: .question(1))?.spec.key.conversationID, legacy)
        XCTAssertTrue(fx.tower.calls(.chatNew).isEmpty)
        XCTAssertEqual(fx.center.count, 1)
        XCTAssertTrue(fx.ai.calls.isEmpty)

        let without = try fx.insertAsk(payload: AskExplainFixture.oneQuestion)
        async let three: Void = fx.vm.openExplain(without, item: .question(1))
        async let four: Void = fx.vm.openExplain(without, item: .question(1))
        _ = await (three, four)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: without, item: .question(1)))
        await engine.started()
        XCTAssertEqual(engine.spec.key.contextID, "\(fx.projectID):\(without.id):q1")
        XCTAssertEqual(try fx.conversationCount(), 2, "the legacy row and one new row")
        XCTAssertEqual(fx.hiddenTurns.count, 1)
        XCTAssertEqual(fx.center.count, 2)
    }

    /// Once a legacy chat exists it wins over an item chat, on every open.
    func testLegacyChatWinsOverAnItemChatOnASingleItemAsk() async throws {
        let ask = try fx.insertAsk(payload: AskExplainFixture.oneQuestion)
        let item = try await fx.conversation(ask, .question(1))
        let legacy = try fx.insertLegacyChat(ask, explanation: "It decides the store.")
        for round in 0..<3 {
            await fx.vm.openExplain(ask, item: .question(1))
            let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(1)), "open \(round)")
            XCTAssertEqual(engine.spec.key.conversationID, legacy, "open \(round)")
            XCTAssertNotEqual(engine.spec.key.conversationID, item)
            fx.vm.closeExplain(ask.id)
            if round == 1 { fx.center.release(engine.spec.key) }
        }
        XCTAssertTrue(fx.ai.calls.isEmpty)
    }

    /// The workbench is deleted after the lookup found the legacy chat: the
    /// chat goes with it, a follow-up's save fails into the shared error
    /// card, and the next open says the workbench is gone, without Retry.
    func testLegacyChatDeletedAfterTheLookupFailsAndTheNextOpenSaysGone() async throws {
        let ask = try fx.insertAsk(payload: AskExplainFixture.oneQuestion)
        _ = try fx.insertLegacyChat(ask, explanation: "It decides the store.")
        await fx.vm.openExplain(ask, item: .question(1))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(1)))
        await waitForCondition { !engine.messages.isEmpty }

        try fx.deleteWorkbench()
        XCTAssertEqual(try fx.conversationCount(), 0, "the legacy chat went with its workbench")
        XCTAssertTrue(engine.send("And option B?"))
        await waitForCondition { !engine.isBusy }
        await engine.finished()
        XCTAssertNotNil(engine.bannerError, "the shared error card")
        XCTAssertEqual(try fx.conversationCount(), 0, "nothing written")

        fx.vm.closeExplain(ask.id)
        await fx.vm.openExplain(ask, item: .question(1))
        XCTAssertEqual(fx.vm.explainErrors[subject(ask)], "This workbench no longer exists.")
        XCTAssertFalse(fx.vm.explainOffersRetry(subject(ask)))
        XCTAssertNil(fx.vm.explainEngine(for: ask, item: .question(1)))
    }

    /// A merge while a reused legacy chat streams: the next open's lookup
    /// finds it under the new bench and adopts the running engine there.
    func testMergeMidStreamMovesARunningLegacyEngine() async throws {
        let ask = try fx.insertAsk(payload: AskExplainFixture.oneQuestion)
        let legacy = try fx.insertLegacyChat(ask)
        await fx.vm.openExplain(ask, item: .question(1))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(1)))
        await engine.started()
        XCTAssertEqual(engine.spec.key.conversationID, legacy, "the empty legacy chat starts the explanation")
        let oldKey = engine.spec.key

        let into = try await fx.pool.write { db -> Int64 in
            let into = try TestDatabase.insertWorkbench(db, name: "beta", folder: "/tmp/acme-explain-beta")
            try db.execute(sql: "UPDATE owner_asks SET project_id = ? WHERE id = ?", arguments: [into, ask.id])
            try db.execute(sql: "UPDATE chat_conversations SET context_id = ? WHERE id = ?",
                           arguments: [AskExplainKey.legacyContextID(workbenchID: into, askID: ask.id), legacy])
            return into
        }
        let stored = try await fx.pool.read { try OwnerAskQueries.ask($0, id: ask.id, projectID: into) }
        let moved = try XCTUnwrap(stored)
        fx.vm.closeExplain(ask.id)
        await fx.vm.openExplain(moved, item: .question(1))

        XCTAssertTrue(fx.vm.explainEngine(for: moved, item: .question(1)) === engine)
        XCTAssertEqual(engine.spec.key.contextID, "\(into):\(ask.id)")
        XCTAssertEqual(engine.spec.key.conversationID, legacy)
        XCTAssertNil(fx.center.loaded(oldKey))
        XCTAssertEqual(fx.center.count, 1)
        XCTAssertTrue(engine.isBusy, "the turn runs on")
        XCTAssertTrue(fx.tower.calls(.chatNew).isEmpty)
        await finishTurn(engine)
        XCTAssertEqual(fx.hiddenTurns.count, 1)
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
        XCTAssertFalse(review.payload.questions.isEmpty, "its payload carries questions")
        await fx.vm.openExplain(review, item: q1)
        XCTAssertFalse(fx.vm.isExplaining(review.id))
        XCTAssertNil(fx.vm.explainItem(review.id))
        XCTAssertTrue(fx.tower.calls(.chatNew).isEmpty)
    }
}

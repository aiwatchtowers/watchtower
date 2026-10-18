import GRDB
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Board #670 phase 2b-2: the chat stores await the writer instead of
/// writing on the main thread. Each test holds GRDB's writer queue
/// (`HeldWriter`, a busy database) and checks the main actor goes on, that
/// nothing is lost or shown wrong while the write waits, and that the write
/// lands once the writer is free.
@MainActor
final class ChatStoresAsyncWriteTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
    }

    private func message(_ id: Int64) async throws -> ChatMessageRecord? {
        try await pool.read { try ChatMessageRecord.fetchOne($0, sql: "SELECT * FROM chat_messages WHERE id = ?", arguments: [id]) }
    }

    // MARK: - Main chat turn driver

    /// A finished turn stays live (its full text on screen, no longer
    /// running) while its final write waits; it leaves, and the screen is
    /// told, once the write landed.
    func testAFinishedTurnStaysShownUntilItsFinalWriteLanded() async throws {
        let (conv, msg) = try await pool.write { db in
            let conv = try TestDatabase.insertChatConversation(db)
            let msg = try ChatTreeQueries.insertAssistant(db, conversationID: conv, parentID: nil, turnID: "t",
                                                          provider: "claude", model: "")
            return (conv, msg.id)
        }
        let driver = ChatTurnDriver(conversationID: conv, store: ChatTurnStore(dbPool: pool))
        var finished = 0
        driver.onTurnFinished = { _ in finished += 1 }
        driver.begin(messageID: msg, turnID: "t")
        let held = HeldWriter(pool)
        defer { held.release() }

        driver.apply(.textDelta(turnID: "t", text: "the whole answer"))
        driver.apply(.turnDone(turnID: "t", status: .complete, sessionID: nil))
        XCTAssertEqual(driver.liveTurn?.fullText, "the whole answer", "still shown while its write waits")
        XCTAssertEqual(driver.liveTurn?.isRunning, false, "and no longer stoppable")
        XCTAssertTrue(driver.isFinishing)
        XCTAssertTrue(driver.isBusy, "no next turn until it landed")
        XCTAssertEqual(finished, 0)

        held.release()
        await driver.writesSettled()
        XCTAssertNil(driver.liveTurn)
        XCTAssertFalse(driver.isBusy)
        XCTAssertEqual(finished, 1)
        let row = try await message(msg)
        XCTAssertEqual(row?.text, "the whole answer")
        XCTAssertEqual(row?.status, "complete")
    }

    // MARK: - Embedded chat engine

    private func engine(ai: ScriptedAIService, conversationID: Int64) -> EmbeddedChatEngine {
        let spec = ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: "idea", contextID: "1", conversationID: conversationID),
            persistence: .database(conversationID: conversationID), toolAccess: .draftOnly,
            systemPrompt: { "S" }, emptyHint: "")
        return EmbeddedChatEngine(spec: spec, store: DatabaseEmbeddedChatStore(dbPool: pool, conversationID: conversationID),
                                  aiService: ai, gate: EmbeddedStreamGate())
    }

    /// The owner's text leaves the composer at once; nothing is sent, no
    /// second send is taken and Stop does nothing until the turn's rows
    /// exist; the turn then goes out once.
    func testAnEmbeddedSendWaitsForItsRowsThenGoesOutOnce() async throws {
        let conv = try await pool.write { try TestDatabase.insertChatConversation($0, contextType: "idea") }
        let ai = ScriptedAIService()
        let engine = engine(ai: ai, conversationID: conv)
        let held = HeldWriter(pool)
        defer { held.release() }

        engine.draft = "first"
        XCTAssertTrue(engine.sendDraft())
        XCTAssertEqual(engine.draft, "")
        XCTAssertTrue(engine.isStarting)
        XCTAssertTrue(engine.isBusy)
        XCTAssertFalse(engine.send("again"), "one turn at a time")
        engine.stop()
        XCTAssertTrue(ai.calls.isEmpty, "nothing is sent before its rows exist")
        engine.draft = "typed meanwhile"

        held.release()
        await engine.started()
        XCTAssertFalse(engine.isStarting)
        XCTAssertTrue(engine.isStreaming, "Stop while the rows were written did not cut the turn")
        XCTAssertEqual(ai.calls.map(\.prompt), ["first"])
        XCTAssertEqual(engine.draft, "typed meanwhile")
        XCTAssertEqual(engine.messages.map(\.message.role), ["user", "assistant"])
    }

    /// A quit while the rows are written: the turn is never sent and ends as
    /// stopped, its owner row kept.
    func testAQuitWhileTheRowsAreWrittenSendsNothingAndKeepsThem() async throws {
        let conv = try await pool.write { try TestDatabase.insertChatConversation($0, contextType: "idea") }
        let ai = ScriptedAIService()
        let engine = engine(ai: ai, conversationID: conv)
        let held = HeldWriter(pool)
        defer { held.release() }

        XCTAssertTrue(engine.send("q"))
        engine.finishAsPartial()
        held.release()
        await engine.finished()

        XCTAssertTrue(ai.calls.isEmpty)
        XCTAssertFalse(engine.isBusy)
        let rows = try await pool.read { try ChatMessageQueries.fetchByConversation($0, conversationID: conv) }
        XCTAssertEqual(rows.map(\.role), ["user", "assistant"])
        XCTAssertEqual(rows.last?.status, "partial")
    }

    /// The quit waits for a reply's final write, so all it streamed is kept.
    func testTheQuitWaitsForAnEmbeddedReplysFinalWrite() async throws {
        let conv = try await pool.write { try TestDatabase.insertChatConversation($0, contextType: "idea") }
        let ai = ScriptedAIService()
        let center = EmbeddedChatCenter { spec, gate in
            EmbeddedChatEngine(spec: spec, store: DatabaseEmbeddedChatStore(dbPool: self.pool, conversationID: conv),
                               aiService: ai, gate: gate)
        }
        let engine = center.engine(for: ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: "idea", contextID: "1", conversationID: conv),
            persistence: .database(conversationID: conv), toolAccess: .draftOnly, systemPrompt: { "S" }, emptyHint: ""))
        engine.send("q")
        await engine.started()
        ai.emit(.text("streamed so far"))
        _ = await eventually { engine.liveTurn?.fullText == "streamed so far" }
        let held = HeldWriter(pool)
        defer { held.release() }

        var quitDone = false
        let quit = Task {
            await center.finishAllAsPartialForQuit()
            quitDone = true
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(quitDone, "the quit waits while the final write waits")
        held.release()
        await quit.value
        let rows = try await pool.read { try ChatMessageQueries.fetchByConversation($0, conversationID: conv) }
        XCTAssertEqual(rows.last?.text, "streamed so far")
        XCTAssertEqual(rows.last?.status, "partial")
    }

    // MARK: - Artifact edit

    /// The editor stays open and editable while an edit is written; text
    /// typed meanwhile stays (the editor stays open over the new version).
    func testTextTypedWhileAnArtifactEditIsWrittenStaysInTheEditor() async throws {
        let (conv, msg) = try await pool.write { db in
            let conv = try TestDatabase.insertChatConversation(db)
            let msg = try TestDatabase.insertChatMessage(db, conversationID: conv, role: "assistant", text: "")
            let draft = ArtifactDraft(key: "q3", kind: "document", title: "Q3", meta: [:], content: "v1", isComplete: true)
            _ = try ChatArtifactQueries.saveVersion(db, conversationID: conv, messageID: msg, draft: draft, edited: false)
            return (conv, msg)
        }
        XCTAssertGreaterThan(msg, 0)
        let model = ArtifactPanelModel(db: pool, conversationID: conv, key: "q3")
        model.beginEdit()
        model.editText = "v1 edited"
        let held = HeldWriter(pool)
        defer { held.release() }

        let save = Task { await model.saveEdit() }
        _ = await eventually { model.isSavingEdit }
        XCTAssertTrue(model.isEditing)
        model.editText = "v1 edited more"
        held.release()
        await save.value

        XCTAssertFalse(model.isSavingEdit)
        XCTAssertTrue(model.isEditing, "typed on: the editor stays open")
        XCTAssertEqual(model.editText, "v1 edited more")
        XCTAssertEqual(model.versions.last?.content, "v1 edited")
        XCTAssertEqual(model.selectedArtifact?.version, 2, "the next save diffs against the stored edit")
    }

    // MARK: - Inbox action strip

    /// A reminder's Done waits for the writer: the card stays and its
    /// buttons wait meanwhile, a second press does nothing, and the card
    /// leaves once the write landed.
    func testAReminderLeavesTheStripOnlyOnceItsDoneLanded() async throws {
        let id = try await pool.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status)
                VALUES ('C1@1','call back','2000-01-01T00:00:00Z','pending')
                """)
            return db.lastInsertedRowID
        }
        let strip = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        strip.refresh()
        XCTAssertEqual(strip.reminderRows.map(\.id), [id])
        let held = HeldWriter(pool)
        defer { held.release() }

        let done = Task { await strip.markReminderDone(id) }
        _ = await eventually { strip.isWriting(reminder: id) }
        XCTAssertEqual(strip.reminderRows.map(\.id), [id], "the card stays while its write waits")
        await strip.markReminderDone(id)
        held.release()
        await done.value

        XCTAssertFalse(strip.isWriting(reminder: id))
        XCTAssertTrue(strip.reminderRows.isEmpty)
        XCTAssertNil(strip.lastError)
    }
}

import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The main chat against a real pool with scripted session processes. The
/// turn is owned by the pool, so several tests release or switch the view
/// model mid-turn (review-rules: start → navigate away → return).
@MainActor
final class ChatViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private(set) var pool: ChatSessionPool!
    private var fakes: [FakeChatSessionProcess] = []
    private var turnCounter = 0
    /// An isolated suite: the view model persists the landing's draft, and
    /// nothing may leak into the test runner's own settings.
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        defaultsSuite = "ChatViewModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        fakes = []
        turnCounter = 0
        pool = ChatSessionPool(
            dbPool: dbManager.dbPool,
            processFactory: { [weak self] args in
                let fake = FakeChatSessionProcess(arguments: args)
                self?.fakes.append(fake)
                return fake
            },
            closeGrace: .milliseconds(20)
        )
    }

    override func tearDown() async throws {
        await pool.closeAll()
        TestDatabase.cleanup(path: dbPath)
        defaults.removePersistentDomain(forName: defaultsSuite)
    }

    func makeViewModel(cliRunner: FakeCLIRunner? = nil) throws -> ChatViewModel {
        ChatViewModel(dbManager: dbManager, pool: pool, provider: .claude, cliRunner: cliRunner,
                      defaults: defaults) { [weak self] in
            guard let self else { return UUID().uuidString }
            self.turnCounter += 1
            return "turn-\(self.turnCounter)"
        }
    }

    private func lastFake() throws -> FakeChatSessionProcess {
        try XCTUnwrap(fakes.last)
    }

    private func lastAssistant(_ conversationID: Int64) throws -> ChatMessageRecord? {
        try dbManager.dbPool.read { d in
            try ChatMessageRecord.fetchOne(d, sql: """
                SELECT * FROM chat_messages WHERE conversation_id = ? AND role = 'assistant' ORDER BY id DESC LIMIT 1
                """, arguments: [conversationID])
        }
    }

    private func complete(_ vm: ChatViewModel, turn: String, text: String) async throws {
        let fake = try lastFake()
        fake.emit(.textDelta(turnID: turn, text: text))
        fake.emit(.turnDone(turnID: turn, status: .complete, sessionID: nil))
        let done = await waitForCondition { !vm.isStreaming && vm.thread.last?.message.status == "complete" }
        XCTAssertTrue(done, "turn \(turn) did not complete")
    }

    /// The active path as Go's `HistoryBefore` would see it at send time.
    private func activePath(_ conversationID: Int64) -> [ChatMessageRecord] {
        (try? dbManager.dbPool.read { d in try ChatTreeQueries.activePath(d, conversationID: conversationID) }) ?? []
    }

    /// The stored text of the newest owner message on `vm`'s active path.
    private func lastStoredUserText(_ vm: ChatViewModel) throws -> String? {
        let id = try XCTUnwrap(vm.conversationID)
        return activePath(id).last { $0.isUser }?.text
    }

    /// The id of the newest owner message on `vm`'s active path.
    private func lastStoredUserID(_ vm: ChatViewModel) throws -> Int64? {
        let id = try XCTUnwrap(vm.conversationID)
        return activePath(id).last { $0.isUser }?.id
    }

    // MARK: - CHAT-01

    /// BEHAVIOR CHAT-01 — see docs/inventory/chat.md
    func testChat01UserMessageIsPersistedBeforeTheTurnIsSent() throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        let fake = try lastFake()
        let db = dbManager.dbPool
        var userRowsAtSend: [String] = []
        fake.onSend = { command in
            guard case .turn = command else { return }
            userRowsAtSend = (try? db.read { d in
                try String.fetchAll(d, sql: "SELECT text FROM chat_messages WHERE conversation_id = ? AND role = 'user'",
                                    arguments: [convID])
            }) ?? []
        }
        XCTAssertTrue(vm.send(text: "hello"))
        XCTAssertEqual(userRowsAtSend, ["hello"])
    }

    /// BEHAVIOR CHAT-01 — see docs/inventory/chat.md
    func testChat01NothingIsSentWhenTheMessageCannotBeSaved() throws {
        let vm = try makeViewModel()
        _ = try XCTUnwrap(vm.newConversation())
        try dbManager.dbPool.write { d in
            try d.execute(sql: """
                CREATE TRIGGER fail_user BEFORE INSERT ON chat_messages WHEN NEW.role = 'user'
                BEGIN SELECT RAISE(ABORT, 'boom'); END
                """)
        }
        vm.draft = "hello"
        vm.sendDraft()
        XCTAssertTrue(try lastFake().turns.isEmpty)
        XCTAssertEqual(vm.draft, "hello", "the owner's text stays in the composer")
        XCTAssertNotNil(vm.errorMessage)
    }

    /// BEHAVIOR CHAT-01 — see docs/inventory/chat.md
    func testChat01PartialTextSurvivesStop() async throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        vm.send(text: "q")
        let fake = try lastFake()
        fake.emit(.textDelta(turnID: "turn-1", text: "Hel"))
        fake.emit(.textDelta(turnID: "turn-1", text: "lo"))
        _ = await waitForCondition { vm.liveTurn?.fullText == "Hello" }
        vm.stop()
        XCTAssertEqual(fake.sent.last, .cancel)
        fake.emit(.turnDone(turnID: "turn-1", status: .interrupted, sessionID: nil))
        let stopped = await waitForCondition { !vm.isStreaming }
        XCTAssertTrue(stopped)
        let row = try XCTUnwrap(lastAssistant(convID))
        XCTAssertEqual(row.text, "Hello")
        XCTAssertEqual(row.status, "partial")
    }

    /// BEHAVIOR CHAT-01 — see docs/inventory/chat.md
    func testChat01PartialTextSurvivesProcessDeathAndTheNextTurnResumes() async throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        vm.send(text: "q")
        let fake = try lastFake()
        fake.emit(.sessionReady(sessionID: "sess-1", provider: "claude", model: "m"))
        fake.emit(.textDelta(turnID: "turn-1", text: "half"))
        fake.exit(status: 9)
        let persisted = await waitForCondition { (try? self.lastAssistant(convID))?.status == "partial" && !vm.isStreaming }
        XCTAssertTrue(persisted)
        XCTAssertEqual(try lastAssistant(convID)?.text, "half")

        XCTAssertTrue(vm.send(text: "again"))
        XCTAssertEqual(fakes.count, 2, "a dead session is respawned")
        XCTAssertEqual(try lastFake().argument(after: "--resume"), "sess-1")
    }

    /// Controller ruling 1: regenerate inserts its assistant row under the NEW
    /// turn id before the turn goes out, and sends that id — Go's
    /// `HistoryBefore` strips it and drops the reused owner question.
    /// BEHAVIOR CHAT-01 — see docs/inventory/chat.md
    func testChat01RegenerateRowExistsUnderTheNewTurnIDWhenSent() async throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        vm.send(text: "q")
        try await complete(vm, turn: "turn-1", text: "a1")
        let fake = try lastFake()
        var atSend: [ChatMessageRecord] = []
        fake.onSend = { [weak self] command in
            if case .turn = command { atSend = self?.activePath(convID) ?? [] }
        }
        vm.regenerate(messageID: try XCTUnwrap(vm.thread.last?.id))
        XCTAssertEqual(fake.turns.last?.turnID, "turn-2")
        XCTAssertEqual(atSend.map(\.role), ["user", "assistant"])
        XCTAssertEqual(atSend.map(\.turnID), ["turn-1", "turn-2"])
        XCTAssertEqual(atSend.last?.status, "partial")
    }

    /// BEHAVIOR CHAT-01 — see docs/inventory/chat.md
    func testChat01EditRowsExistUnderTheNewTurnIDWhenSent() async throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        vm.send(text: "q")
        try await complete(vm, turn: "turn-1", text: "a1")
        let fake = try lastFake()
        var atSend: [ChatMessageRecord] = []
        fake.onSend = { [weak self] command in
            if case .turn = command { atSend = self?.activePath(convID) ?? [] }
        }
        vm.edit(messageID: try XCTUnwrap(vm.thread.first?.id), newText: "q2")
        XCTAssertEqual(fake.turns.last?.turnID, "turn-2")
        XCTAssertEqual(atSend.map(\.text), ["q2", ""])
        XCTAssertEqual(atSend.map(\.turnID), ["turn-2", "turn-2"])
    }

    /// Controller ruling 1: a failed turn never leaves its owner message
    /// unanswered — the next turn sits after an `error` assistant row, so
    /// `HistoryBefore` has no trailing question to silently drop.
    /// BEHAVIOR CHAT-01 — see docs/inventory/chat.md
    func testChat01FailedSendKeepsTheOwnerMessageAnswered() async throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        let fake = try lastFake()
        fake.sendError = CocoaError(.fileWriteUnknown)
        XCTAssertTrue(vm.send(text: "q"))
        let failed = await waitForCondition { vm.thread.last?.message.status == "error" }
        XCTAssertTrue(failed)
        XCTAssertEqual(vm.thread.map(\.message.role), ["user", "assistant"])

        fake.sendError = nil
        var atSend: [ChatMessageRecord] = []
        fake.onSend = { [weak self] command in
            if case .turn = command { atSend = self?.activePath(convID) ?? [] }
        }
        XCTAssertTrue(vm.send(text: "q2"))
        XCTAssertEqual(atSend.map(\.role), ["user", "assistant", "user", "assistant"])
        XCTAssertEqual(atSend.map(\.status), ["complete", "error", "complete", "partial"])
        XCTAssertEqual(fake.turns.last?.replay, true, "a failed turn forces a replay")
    }

    /// A legacy conversation whose last owner question never got a reply:
    /// the next turn first records that question as answered-by-nothing
    /// (`partial`, empty), so the replay keeps it instead of dropping it.
    /// BEHAVIOR CHAT-01 — see docs/inventory/chat.md
    func testChat01LegacyUnansweredQuestionIsKeptBeforeTheNextTurn() throws {
        let (convID, question) = try dbManager.dbPool.write { d in
            let conv = try TestDatabase.insertChatConversation(d, title: "Old")
            let user = try TestDatabase.insertChatMessage(d, conversationID: conv, role: "user", text: "old q")
            return (conv, user)
        }
        let vm = try makeViewModel()
        vm.select(conversationID: convID)
        XCTAssertTrue(vm.send(text: "next"))
        let path = activePath(convID)
        XCTAssertEqual(path.map(\.role), ["user", "assistant", "user", "assistant"])
        XCTAssertEqual(path[0].id, question)
        XCTAssertEqual(path[1].status, "partial")
        XCTAssertEqual(path[1].text, "")
        XCTAssertEqual(path[2].text, "next")
    }

    // MARK: - Navigation (review-rules: start → navigate away → return)

    func testTurnKeepsPersistingAfterViewModelIsReleased() async throws {
        var vm: ChatViewModel? = try makeViewModel()
        let convID = try XCTUnwrap(vm?.newConversation())
        XCTAssertEqual(vm?.send(text: "q"), true)
        let fake = try lastFake()
        weak var released = vm
        vm = nil
        XCTAssertNil(released, "the turn is owned by the pool, not by the view model")

        fake.emit(.textDelta(turnID: "turn-1", text: "Hello"))
        fake.emit(.turnDone(turnID: "turn-1", status: .complete, sessionID: nil))
        let persisted = await waitForCondition { (try? self.lastAssistant(convID))?.status == "complete" }
        XCTAssertTrue(persisted)

        let back = try makeViewModel()
        back.select(conversationID: convID)
        XCTAssertEqual(back.thread.last?.message.text, "Hello")
    }

    func testSwitchingConversationMidTurnAndBackShowsTheLiveTurn() async throws {
        let vm = try makeViewModel()
        let first = try XCTUnwrap(vm.newConversation())
        vm.send(text: "q")
        let firstFake = try lastFake()
        _ = vm.newConversation()

        firstFake.emit(.textDelta(turnID: "turn-1", text: "Hel"))
        _ = await waitForCondition { self.pool.client(for: first)?.liveTurn?.fullText == "Hel" }
        vm.select(conversationID: first)
        XCTAssertTrue(vm.isStreaming)
        XCTAssertEqual(vm.liveTurn?.fullText, "Hel")
        XCTAssertEqual(vm.thread.last?.id, vm.liveTurn?.messageID, "the live row replaces the partial assistant row")

        firstFake.emit(.textDelta(turnID: "turn-1", text: "lo"))
        firstFake.emit(.turnDone(turnID: "turn-1", status: .complete, sessionID: nil))
        let done = await waitForCondition { vm.thread.last?.message.text == "Hello" }
        XCTAssertTrue(done)
    }

    // MARK: - Pool queue (controller ruling 4)

    /// With three turns in flight the fourth conversation's turn is held by
    /// the pool; the view model says so, and the turn goes out once a slot frees.
    func testFourthConversationWaitsForAFreeSession() async throws {
        let vm = try makeViewModel()
        for index in 1...3 {
            _ = vm.newConversation()
            XCTAssertTrue(vm.send(text: "q\(index)"))
        }
        XCTAssertEqual(fakes.count, 3)
        _ = vm.newConversation()
        XCTAssertTrue(vm.send(text: "q4"))
        XCTAssertEqual(fakes.count, 3, "a busy session is never evicted")
        XCTAssertTrue(vm.isWaitingForSession)
        XCTAssertTrue(vm.isStreaming, "a held turn counts as running: no second send")

        fakes[0].emit(.turnDone(turnID: "turn-1", status: .complete, sessionID: nil))
        let launched = await waitForCondition { self.fakes.count == 4 && self.fakes[3].turns.count == 1 }
        XCTAssertTrue(launched)
        XCTAssertEqual(fakes[3].turns.first?.turnID, "turn-4")
        XCTAssertFalse(vm.isWaitingForSession)
    }

    /// Stopping a held turn keeps its owner message answered (`partial`).
    func testStoppingAHeldTurnLeavesAPartialReply() throws {
        let vm = try makeViewModel()
        for index in 1...3 {
            _ = vm.newConversation()
            vm.send(text: "q\(index)")
        }
        let waiting = try XCTUnwrap(vm.newConversation())
        vm.send(text: "q4")
        XCTAssertTrue(vm.isWaitingForSession)
        vm.stop()
        XCTAssertFalse(vm.isStreaming)
        XCTAssertFalse(vm.isWaitingForSession)
        XCTAssertEqual(activePath(waiting).map(\.status), ["complete", "partial"])
    }

    /// A held turn stopped before launch never reached the provider: the
    /// next send must replay, or the stopped question is silently lost.
    func testSendAfterStoppingAHeldTurnReplays() async throws {
        let vm = try makeViewModel()
        for index in 1...3 {
            _ = vm.newConversation()
            vm.send(text: "q\(index)")
        }
        _ = vm.newConversation()
        vm.send(text: "q4")
        vm.stop()
        XCTAssertTrue(vm.send(text: "q5"))
        XCTAssertTrue(vm.isWaitingForSession)

        fakes[0].emit(.turnDone(turnID: "turn-1", status: .complete, sessionID: nil))
        let launched = await waitForCondition { self.fakes.count == 4 && self.fakes[3].turns.count == 1 }
        XCTAssertTrue(launched)
        XCTAssertEqual(fakes[3].turns.first?.turnID, "turn-5")
        XCTAssertEqual(fakes[3].turns.first?.replay, true, "the stopped q4 was never sent")
    }

    // MARK: - Render isolation (skeleton Review Focus #5)

    func testDeltasDoNotInvalidateTheThread() async throws {
        final class Flag: @unchecked Sendable { var fired = false }
        let vm = try makeViewModel()
        _ = vm.newConversation()
        vm.send(text: "q")
        let fake = try lastFake()
        let flag = Flag()
        withObservationTracking { _ = vm.thread } onChange: { flag.fired = true }
        for _ in 0..<50 { fake.emit(.textDelta(turnID: "turn-1", text: "x")) }
        let streamed = await waitForCondition { vm.liveTurn?.fullText.count == 50 }
        XCTAssertTrue(streamed)
        XCTAssertFalse(flag.fired, "a delta touches only LiveTurn, never the thread array")
    }

    // MARK: - Legacy (skeleton Review Focus #1)

    func testContinuingLegacyConversationResumesItsSession() throws {
        let (convID, lastID) = try dbManager.dbPool.write { d in
            let conv = try TestDatabase.insertChatConversation(d, title: "Old", sessionID: "sess-legacy")
            let user = try TestDatabase.insertChatMessage(d, conversationID: conv, role: "user", text: "old q")
            let asst = try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: "old a", parentID: user)
            return (conv, asst)
        }
        let vm = try makeViewModel()
        vm.select(conversationID: convID)
        XCTAssertEqual(vm.thread.map(\.message.text), ["old q", "old a"])

        XCTAssertTrue(vm.send(text: "next"))
        let fake = try lastFake()
        XCTAssertEqual(fake.argument(after: "--resume"), "sess-legacy")
        XCTAssertEqual(fake.turns.last?.replay, false, "the resumed session already holds this history")
        let user = try XCTUnwrap(vm.thread.first { $0.message.text == "next" })
        XCTAssertEqual(user.message.parentID, lastID)
    }

    /// The stored claude session saw only the claude turns: when another
    /// provider answered last, resuming it without a replay would skip them.
    func testResumedSessionReplaysWhenAnotherProviderAnsweredLast() throws {
        let convID = try dbManager.dbPool.write { d in
            let conv = try TestDatabase.insertChatConversation(d, sessionID: "sess-1", provider: "claude")
            let user = try TestDatabase.insertChatMessage(d, conversationID: conv, role: "user", text: "q")
            let asst = try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: "a", parentID: user)
            try d.execute(sql: "UPDATE chat_messages SET provider = 'codex' WHERE id = ?", arguments: [asst])
            return conv
        }
        let vm = try makeViewModel()
        vm.select(conversationID: convID)
        XCTAssertTrue(vm.send(text: "next"))
        XCTAssertEqual(try lastFake().argument(after: "--resume"), "sess-1")
        XCTAssertEqual(try lastFake().turns.last?.replay, true)
    }

    /// A newest reply that failed, or was cut before any text, may never
    /// have reached the provider: a `--resume` spawn must replay past it.
    func testResumedSessionReplaysWhenTheNewestReplyNeverProvablyArrived() throws {
        for status in ["error", "partial"] {
            let convID = try dbManager.dbPool.write { d in
                let conv = try TestDatabase.insertChatConversation(d, sessionID: "sess-\(status)", provider: "claude")
                let user = try TestDatabase.insertChatMessage(d, conversationID: conv, role: "user", text: "q")
                let asst = try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: "",
                                                              parentID: user, status: status)
                try d.execute(sql: "UPDATE chat_messages SET provider = 'claude' WHERE id = ?", arguments: [asst])
                return conv
            }
            let vm = try makeViewModel()
            vm.select(conversationID: convID)
            XCTAssertTrue(vm.send(text: "next"))
            XCTAssertEqual(try lastFake().argument(after: "--resume"), "sess-\(status)")
            XCTAssertEqual(try lastFake().turns.last?.replay, true, "newest reply is \(status)")
        }
    }

    // MARK: - Branches

    /// The ACTIONS block belongs to a plain send: regenerate/edit branch away
    /// from the turn that proposed those actions.
    func testRegenerateAndEditDropTheOutcomesBlock() async throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        vm.send(text: "q")
        try await complete(vm, turn: "turn-1", text: "a1")
        let applied = AgentActionFeed.timestampString(Date().addingTimeInterval(60))
        _ = try await dbManager.dbPool.write { d in
            try TestDatabase.insertAgentAction(d, conversationID: convID, status: "applied",
                                               resultJSON: #"{"target_id":5}"#, appliedAt: applied)
        }
        _ = await waitForCondition { vm.actionFeed.rows.count == 1 }
        XCTAssertNotNil(vm.actionFeed.outcomesBlock(after: vm.thread.first?.message.createdDate))

        vm.regenerate(messageID: try XCTUnwrap(vm.thread.last?.id))
        XCTAssertEqual(try lastFake().turns.last?.text, "q")
        try await complete(vm, turn: "turn-2", text: "a2")

        vm.edit(messageID: try XCTUnwrap(vm.thread.first?.id), newText: "q2")
        XCTAssertEqual(try lastFake().turns.last?.text, "q2")
    }

    func testRegenerateMakesASiblingReplaysAndVariantsSwitch() async throws {
        let vm = try makeViewModel()
        _ = vm.newConversation()
        vm.send(text: "q")
        try await complete(vm, turn: "turn-1", text: "a1")
        let firstAnswer = try XCTUnwrap(vm.thread.last?.id)

        vm.regenerate(messageID: firstAnswer)
        let fake = try lastFake()
        XCTAssertEqual(fake.turns.last?.text, "q")
        XCTAssertEqual(fake.turns.last?.replay, true)
        try await complete(vm, turn: "turn-2", text: "a2")
        XCTAssertEqual(vm.thread.map(\.message.text), ["q", "a2"], "regenerate never duplicates the user message")
        XCTAssertEqual(vm.thread.last?.siblingIndex, 2)
        XCTAssertEqual(vm.thread.last?.siblingCount, 2)

        let previous = try XCTUnwrap(vm.variant(of: try XCTUnwrap(vm.thread.last?.id), offset: -1))
        vm.selectVariant(messageID: previous)
        XCTAssertEqual(vm.thread.last?.message.text, "a1")
        XCTAssertNil(vm.variant(of: previous, offset: -1))
    }

    /// A ‹ › switch away from the answer whose sources are shown closes the
    /// panel — it never keeps a hidden variant's sources on screen.
    func testSourcesPanelClosesWhenItsAnswerLeavesTheBranch() async throws {
        let vm = try makeViewModel()
        _ = vm.newConversation()
        vm.send(text: "q")
        try await complete(vm, turn: "turn-1", text: "a1")
        let firstAnswer = try XCTUnwrap(vm.thread.last?.id)
        let sources = ChatSource.encodeList([ChatSource(kind: "jira", title: "PAY-1", url: nil, ref: "jira:PAY-1")])
        try await dbManager.dbPool.write { d in
            try ChatStepQueries.upsertStart(d, messageID: firstAnswer, seq: 0, toolID: "a", name: "get_jira_issue",
                                            argsJSON: "{}", startedAt: 1)
            try ChatStepQueries.finish(d, messageID: firstAnswer, toolID: "a", ok: true, summary: "s",
                                       sourcesJSON: sources, endedAt: 2)
        }
        vm.reload()
        let item = try XCTUnwrap(vm.thread.last)
        vm.openSources(messageID: item.id, sources: item.sources)
        vm.reload()
        XCTAssertEqual(vm.sourcesPanel?.sources.count, 1, "a reload of the same branch keeps the panel")

        vm.regenerate(messageID: firstAnswer)
        try await complete(vm, turn: "turn-2", text: "a2")
        XCTAssertNil(vm.sourcesPanel, "the shown answer is now a hidden variant")
    }

    func testEditMakesAUserSiblingAndReplays() async throws {
        let vm = try makeViewModel()
        _ = vm.newConversation()
        vm.send(text: "q")
        try await complete(vm, turn: "turn-1", text: "a1")
        let userID = try XCTUnwrap(vm.thread.first?.id)

        vm.edit(messageID: userID, newText: "q2")
        XCTAssertEqual(try lastFake().turns.last?.text, "q2")
        XCTAssertEqual(try lastFake().turns.last?.replay, true)
        try await complete(vm, turn: "turn-2", text: "a2")
        XCTAssertEqual(vm.thread.map(\.message.text), ["q2", "a2"])
        XCTAssertEqual(vm.thread.first?.siblingCount, 2)
    }

    func testErrorMarksTheMessageAndRetryRegenerates() async throws {
        let vm = try makeViewModel()
        _ = vm.newConversation()
        vm.send(text: "q")
        let fake = try lastFake()
        fake.emit(.error(ChatSessionError(turnID: "turn-1", code: .rateLimit, message: "slow", retryable: true)))
        let failed = await waitForCondition { vm.thread.last?.message.status == "error" }
        XCTAssertTrue(failed)
        XCTAssertEqual(vm.thread.last?.message.errorCode, "rate_limit")

        vm.retry(messageID: try XCTUnwrap(vm.thread.last?.id))
        XCTAssertEqual(fake.turns.count, 2)
        XCTAssertEqual(fake.turns.last?.replay, true, "a failed turn may not have reached the provider")
    }

    func testContinueStoppedSendsContinue() async throws {
        let vm = try makeViewModel()
        _ = vm.newConversation()
        vm.send(text: "q")
        let fake = try lastFake()
        fake.emit(.turnDone(turnID: "turn-1", status: .interrupted, sessionID: nil))
        _ = await waitForCondition { !vm.isStreaming }
        vm.continueStopped(messageID: try XCTUnwrap(vm.thread.last?.id))
        XCTAssertEqual(fake.turns.last?.text, "Continue")
    }

    func testSendingWhileStreamingIsRefused() throws {
        let vm = try makeViewModel()
        _ = vm.newConversation()
        XCTAssertTrue(vm.send(text: "q"))
        XCTAssertFalse(vm.send(text: "again"))
        XCTAssertFalse(vm.send(text: "   "))
    }

    /// Degenerate clean-exit branch: no text and no attachments is simply
    /// nothing to send — not an error, not a turn.
    /// The main chat's provider follows config.yaml's `ai.provider` —
    /// ollama included (it used to be mapped to Claude); unset or unknown is Claude.
    func testAIProviderFromConfig() {
        XCTAssertEqual(AIProvider.fromConfig("codex"), .codex)
        XCTAssertEqual(AIProvider.fromConfig("ollama"), .ollama)
        XCTAssertEqual(AIProvider.fromConfig("claude"), .claude)
        XCTAssertEqual(AIProvider.fromConfig(nil), .claude)
        XCTAssertEqual(AIProvider.fromConfig("something-else"), .claude)
    }

    func testSendingNothingIsRefused() throws {
        let vm = try makeViewModel()
        _ = vm.newConversation()
        XCTAssertFalse(vm.send(text: "   ", attachments: []))
        XCTAssertTrue(vm.thread.isEmpty)
    }

    /// A message may carry only attachments (spec §7.1 / preflight A39): the
    /// composer's canSend twin, and the attachment rows are linked to the new
    /// owner message in the SAME transaction that persists it (CHAT-01).
    func testSendWithOnlyAttachmentsSucceedsAndLinksInTheSameTransaction() throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        let att = try dbManager.dbPool.write { db in
            try ChatAttachmentQueries.insert(db, owner: .conversation(convID), name: "shot.png", mime: "image/png",
                                             size: 3, path: "/tmp/shot.png", sha256: "abc")
        }
        XCTAssertTrue(vm.send(text: "", attachments: [att]))

        let userMessageID = try XCTUnwrap(activePath(convID).first?.id)
        let linked = try dbManager.dbPool.read { db in
            try ChatAttachmentQueries.fetchByMessages(db, messageIDs: [userMessageID])
        }
        XCTAssertEqual(linked[userMessageID]?.map(\.id), [att.id])

        // The wire command carries only path/mime/name — never the row id.
        let sent = try XCTUnwrap(lastFake().turns.last?.attachments)
        XCTAssertEqual(sent, [ChatCommandAttachment(path: "/tmp/shot.png", mime: "image/png", name: "shot.png")])
    }

    /// Replay is text-only: retry/regenerate and edit re-send the original
    /// owner message's files, or the model answers as if nothing was attached.
    func testRegenerateRetryAndEditResendTheOwnerMessagesAttachments() async throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        let att = try await dbManager.dbPool.write { db in
            try ChatAttachmentQueries.insert(db, owner: .conversation(convID), name: "spec.pdf", mime: "application/pdf",
                                             size: 3, path: "/tmp/spec.pdf", sha256: "abc")
        }
        let wire = [ChatCommandAttachment(path: "/tmp/spec.pdf", mime: "application/pdf", name: "spec.pdf")]
        XCTAssertTrue(vm.send(text: "summarize", attachments: [att]))
        let fake = try lastFake()
        fake.emit(.error(ChatSessionError(turnID: "turn-1", code: .rateLimit, message: "slow", retryable: true)))
        _ = await waitForCondition { vm.thread.last?.message.status == "error" }

        vm.retry(messageID: try XCTUnwrap(vm.thread.last?.id))
        XCTAssertEqual(fake.turns.count, 2)
        XCTAssertEqual(fake.turns.last?.attachments, wire, "retry re-sends the file")
        try await complete(vm, turn: "turn-2", text: "a2")

        vm.regenerate(messageID: try XCTUnwrap(vm.thread.last?.id))
        XCTAssertEqual(try lastFake().turns.last?.attachments, wire, "regenerate re-sends the file")
        try await complete(vm, turn: "turn-3", text: "a3")

        vm.edit(messageID: try XCTUnwrap(vm.thread.first?.id), newText: "summarize briefly")
        XCTAssertEqual(try lastFake().turns.last?.attachments, wire, "edit keeps the original's files")
        let linked = try await dbManager.dbPool.read { db in try ChatAttachment.fetchAll(db, sql: "SELECT * FROM chat_attachments") }
        XCTAssertEqual(linked.count, 1, "no attachment row is duplicated")
        XCTAssertNotNil(linked.first?.messageID)
    }

    /// The skill line and finished REFERENCED tokens (for mentions still
    /// present in the text) are both part of the stored (and sent) owner text.
    func testMentionsAndSkillArePartOfTheStoredText() throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        let pay = MentionCandidate(kind: .jira, ref: "PAY-1", label: "PAY-1", detail: "")
        XCTAssertTrue(vm.send(text: "look at @PAY-1", mentions: [pay], skill: "status-update"))
        let expected = "Use skill status-update: load it with load_skill first.\n\nlook at @PAY-1\n\n"
            + "REFERENCED: jira:PAY-1 \"PAY-1\""
        XCTAssertEqual(activePath(convID).first?.text, expected)
        XCTAssertEqual(try lastFake().turns.last?.text, expected)
    }

    /// @-mentions and REFERENCED tokens (spec §6.2): `send` filters the picked
    /// mentions down to those still present in the text, composes them into
    /// the stored/sent owner text, and clears the draft's pending mentions.
    func testSendAppendsReferencedLineForLiveMentionsAndPersistsIt() throws {
        let vm = try makeViewModel()
        _ = try XCTUnwrap(vm.newConversation())
        let anna = MentionCandidate(kind: .person, ref: "1:U1", label: "Anna", detail: "")
        let gone = MentionCandidate(kind: .jira, ref: "PAY-1", label: "PAY-1", detail: "")
        vm.send(text: "ask @Anna", attachments: [], mentions: [anna, gone])

        let expected = "ask @Anna\n\nREFERENCED: person:1:U1 \"Anna\""
        XCTAssertEqual(try lastFake().turns.last?.text.hasPrefix(expected), true,
                       "the turn text carries the live mention only")
        XCTAssertEqual(try lastStoredUserText(vm), expected, "what was sent is what is stored (CHAT-01)")
        XCTAssertTrue(vm.composer.mentions.isEmpty, "the draft's mentions are cleared after send")
    }

    /// Editing a message keeps its references (Review Focus 3). `edit` refuses
    /// while streaming (like `send`), so the first turn must finish first.
    func testEditKeepsReferences() async throws {
        let vm = try makeViewModel()
        _ = try XCTUnwrap(vm.newConversation())
        let pay = MentionCandidate(kind: .jira, ref: "PAY-1", label: "PAY-1", detail: "")
        vm.send(text: "look at @PAY-1", attachments: [], mentions: [pay])
        try await complete(vm, turn: "turn-1", text: "a")
        let messageID = try XCTUnwrap(try lastStoredUserID(vm))
        vm.edit(messageID: messageID, newText: "now @PAY-1 again")
        XCTAssertEqual(try lastStoredUserText(vm),
                       "now @PAY-1 again\n\nREFERENCED: jira:PAY-1 \"PAY-1\"")
    }

    // MARK: - Titles, outcomes, settings

    func testTitleIsRequestedOnceAfterTheFirstCompletedTurn() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"title":"T","written":true}"#.utf8))
        let vm = try makeViewModel(cliRunner: runner)
        let convID = try XCTUnwrap(vm.newConversation())
        vm.send(text: "q")
        try await complete(vm, turn: "turn-1", text: "a")
        _ = await waitForCondition { runner.invocations.count == 1 }
        vm.send(text: "q2")
        try await complete(vm, turn: "turn-2", text: "b")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runner.invocations, [["chat", "title", String(convID)]])
    }

    /// A failed `chat title` is not retried on later turns (once per
    /// conversation per app run) — even though the count still says "needed".
    func testTitleIsNotRetriedAfterAFailedCall() async throws {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "boom"))
        let vm = try makeViewModel(cliRunner: runner)
        let convID = try XCTUnwrap(vm.newConversation())
        vm.send(text: "q")
        try await complete(vm, turn: "turn-1", text: "a")
        _ = await waitForCondition { runner.invocations.count == 1 }
        vm.send(text: "q2")
        try lastFake().emit(.turnDone(turnID: "turn-2", status: .interrupted, sessionID: nil))
        _ = await waitForCondition { !vm.isStreaming }
        let stillNeeded = try await dbManager.dbPool.read { d in try ChatConversationQueries.needsAITitle(d, id: convID) }
        XCTAssertTrue(stillNeeded)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runner.invocations.count, 1)
    }

    /// The prefix title is the owner's words, not the skill/REFERENCED lines.
    func testPrefixTitleUsesTheOwnersWords() throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        let pay = MentionCandidate(kind: .jira, ref: "PAY-1", label: "PAY-1", detail: "")
        XCTAssertTrue(vm.send(text: "look at @PAY-1", mentions: [pay], skill: "status-update"))
        XCTAssertEqual(try dbManager.dbPool.read { d in try ChatConversationQueries.fetchByID(d, id: convID)?.title },
                       "look at @PAY-1")
    }

    /// The `/` skill picker prefixes the skill line into the stored/sent
    /// owner text (Task 26).
    func testSendWithSkillPrefixesTheSkillLine() throws {
        let vm = try makeViewModel()
        _ = try XCTUnwrap(vm.newConversation())
        vm.send(text: "for PAY", attachments: [], mentions: [], skill: "status-update")
        XCTAssertEqual(try lastStoredUserText(vm),
                       "Use skill status-update: load it with load_skill first.\n\nfor PAY")
    }

    /// Ported from the old outcomes test: codex never emits a session id, so
    /// the floor is the previous owner message, not the session.
    func testOutcomesOfProposalsPrefixTheNextTurn() async throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        vm.send(text: "first")
        try await complete(vm, turn: "turn-1", text: "a")
        let applied = AgentActionFeed.timestampString(Date().addingTimeInterval(60))
        _ = try await dbManager.dbPool.write { d in
            try TestDatabase.insertAgentAction(d, conversationID: convID, status: "applied",
                                               resultJSON: #"{"target_id":5}"#, appliedAt: applied)
        }
        _ = await waitForCondition { vm.actionFeed.rows.count == 1 }
        vm.send(text: "second")
        let text = try XCTUnwrap(lastFake().turns.last?.text)
        XCTAssertTrue(text.hasPrefix("=== ACTIONS SINCE YOUR LAST MESSAGE ==="))
        XCTAssertTrue(text.contains("create_target: applied"))
        XCTAssertTrue(text.hasSuffix("second"))
        XCTAssertEqual(activePath(convID).last { $0.isUser }?.text, "second", "the block is sent, never stored")
    }

    func testSelectRestoresTheConversationsProviderAndModel() throws {
        let convID = try dbManager.dbPool.write { d in
            let conv = try TestDatabase.insertChatConversation(d, provider: "codex")
            try d.execute(sql: "UPDATE chat_conversations SET model = 'model-b' WHERE id = ?", arguments: [conv])
            return conv
        }
        let vm = try makeViewModel()
        vm.select(conversationID: convID)
        XCTAssertEqual(vm.selectedProvider, .codex)
        XCTAssertEqual(vm.selectedModel, "model-b")
        XCTAssertEqual(try lastFake().argument(after: "--provider"), "codex")
        XCTAssertNil(try lastFake().argument(after: "--resume"), "only claude resumes")
    }

    /// The artifact and sources panels share the inspector without closing
    /// each other (ChatInspectorPolicy); a conversation switch closes both.
    func testSourcesPanelSharesTheInspectorWithAnOpenArtifact() throws {
        let vm = try makeViewModel()
        XCTAssertNotNil(vm.newConversation())
        let source = ChatSource(kind: "jira", title: "PAY-1: A", url: nil, ref: "jira:PAY-1", group: "PAY")
        vm.openArtifact(key: "q3")
        XCTAssertEqual(vm.inspectorMode, .artifacts)
        vm.openSources(messageID: 7, sources: [source, source])
        XCTAssertEqual(vm.inspectorMode, .sources)
        XCTAssertEqual(vm.artifactPanel?.key, "q3", "opening sources keeps the artifact open behind its tab")
        XCTAssertEqual(vm.sourcesPanel?.sources.count, 1)
        vm.closeSourcesPanel()
        XCTAssertEqual(vm.inspectorMode, .artifacts, "closing sources falls back to the artifact")
        vm.openSources(messageID: 7, sources: [])
        XCTAssertNil(vm.sourcesPanel, "an answer without sources opens nothing")
        vm.openSources(messageID: 7, sources: [source])
        XCTAssertNotNil(vm.newConversation())
        XCTAssertNil(vm.inspectorMode, "switching conversations closes both panels")
        vm.openSources(messageID: 8, sources: [source])
        vm.closeInspector()
        XCTAssertNil(vm.inspectorMode)
    }

    func testOpeningASearchHitShowsItsBranchAndScrollsToIt() async throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        vm.send(text: "q")
        try await complete(vm, turn: "turn-1", text: "first answer")
        let firstAnswer = try XCTUnwrap(vm.thread.last?.id)
        vm.regenerate(messageID: firstAnswer)
        try await complete(vm, turn: "turn-2", text: "second answer")
        _ = vm.newConversation()

        vm.open(ChatSearchHit(conversationID: convID, messageID: firstAnswer, title: "", snippet: ""))
        XCTAssertEqual(vm.conversationID, convID)
        XCTAssertEqual(vm.thread.last?.id, firstAnswer, "the hit's branch becomes the active one")
        XCTAssertEqual(vm.scrollTarget, firstAnswer)
    }

    /// Once the thread view consumed a jump, reopening the same hit sets the
    /// target again, so the view jumps again instead of seeing no change.
    func testConsumedScrollTargetLetsTheSameHitJumpAgain() async throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        vm.send(text: "q")
        try await complete(vm, turn: "turn-1", text: "answer")
        let answer = try XCTUnwrap(vm.thread.last?.id)
        let hit = ChatSearchHit(conversationID: convID, messageID: answer, title: "", snippet: "")

        vm.open(hit)
        XCTAssertEqual(vm.scrollTarget, answer)
        vm.consumeScrollTarget()
        XCTAssertNil(vm.scrollTarget)
        vm.open(hit)
        XCTAssertEqual(vm.scrollTarget, answer)
    }

    /// Degenerate: consuming with no pending target is a no-op.
    func testConsumingWithoutATargetIsANoOp() throws {
        let vm = try makeViewModel()
        vm.consumeScrollTarget()
        XCTAssertNil(vm.scrollTarget)
    }

    func testArrowUpEditsTheLastUserMessage() async throws {
        let vm = try makeViewModel()
        _ = vm.newConversation()
        vm.send(text: "q")
        try await complete(vm, turn: "turn-1", text: "a")
        vm.beginEditingLast()
        XCTAssertEqual(vm.editingMessageID, vm.thread.first?.id)
    }

    // MARK: - Provider / model recycling (spec §1.4)

    func testSwitchingProviderClosesTheSessionAndTheNextTurnUsesTheNewProvider() async throws {
        let vm = try makeViewModel()
        _ = vm.newConversation()
        let first = try lastFake()
        vm.switchProvider(.codex)
        let closed = await waitForCondition { first.sent.contains(.close) }
        XCTAssertTrue(closed)
        XCTAssertTrue(vm.send(text: "q"))
        // The pool never overlaps a config-change replacement with the
        // process it replaces (ChatSessionPoolTests precedent): the new
        // session stays pending until the old one's retirement finishes.
        let spawned = await waitForCondition { self.fakes.count == 2 }
        XCTAssertTrue(spawned)
        XCTAssertEqual(try lastFake().argument(after: "--provider"), "codex")
        XCTAssertNil(try lastFake().argument(after: "--resume"), "codex replays instead of resuming")
    }

    func testChangingModelKeepsClaudeResume() async throws {
        let convID = try await dbManager.dbPool.write { d in
            try TestDatabase.insertChatConversation(d, sessionID: "s1", provider: "claude")
        }
        let vm = try makeViewModel()
        vm.select(conversationID: convID)
        let first = try lastFake()
        vm.selectedModel = "model-b"
        let closed = await waitForCondition { first.sent.contains(.close) }
        XCTAssertTrue(closed)
        XCTAssertTrue(vm.send(text: "q"))
        let spawned = await waitForCondition { self.fakes.count == 2 }
        XCTAssertTrue(spawned)
        XCTAssertEqual(try lastFake().argument(after: "--model"), "model-b")
        XCTAssertEqual(try lastFake().argument(after: "--resume"), "s1")
    }

    /// Restoring a conversation's own provider/model on select is not a change.
    func testSelectingAConversationDoesNotRecycleItsOwnSession() throws {
        let convID = try dbManager.dbPool.write { d in
            let conv = try TestDatabase.insertChatConversation(d, provider: "codex")
            try d.execute(sql: "UPDATE chat_conversations SET model = 'model-b' WHERE id = ?", arguments: [conv])
            return conv
        }
        let vm = try makeViewModel()
        vm.select(conversationID: convID)
        XCTAssertEqual(fakes.count, 1)
        XCTAssertFalse(try lastFake().sent.contains(.close))
    }

    // MARK: - Projects (Task 24)

    func testCreateProjectOpensItAndSelectingAConversationLeavesIt() throws {
        let vm = try makeViewModel()
        let id = try XCTUnwrap(vm.createProject(name: "Payments"))
        XCTAssertEqual(vm.openProjectID, id)
        XCTAssertEqual(vm.projects.map(\.name), ["Payments"])

        vm.newConversation(projectID: id)
        XCTAssertNil(vm.openProjectID, "starting a chat leaves the project page")
        XCTAssertEqual(vm.currentConversation?.projectID, id)

        vm.openProject(id)
        XCTAssertEqual(vm.openProjectID, id)
        vm.select(conversationID: try XCTUnwrap(vm.currentConversation?.id))
        XCTAssertNil(vm.openProjectID)
    }

    func testProjectsAreLoadedAtStart() throws {
        try dbManager.dbPool.write { _ = try ChatProjectQueries.create($0, name: "Existing") }
        let vm = try makeViewModel()
        XCTAssertEqual(vm.projects.map(\.name), ["Existing"])
    }

    func testNewConversationInProjectPassesProjectIDToTheSession() throws {
        let vm = try makeViewModel()
        let id = try XCTUnwrap(vm.createProject(name: "P"))
        vm.newConversation(projectID: id)
        vm.send(text: "hi")
        XCTAssertEqual(pool.lastConfig?.projectID, id)
        let args = try lastFake().arguments
        XCTAssertEqual(args.firstIndex(of: "--project-id").map { args[$0 + 1] }, String(id))
    }

    func testChatOutsideAProjectHasNoProjectFlag() throws {
        let vm = try makeViewModel()
        vm.newConversation()
        vm.send(text: "hi")
        XCTAssertNil(pool.lastConfig?.projectID)
        XCTAssertFalse(try lastFake().arguments.contains("--project-id"))
    }

    /// Moving the shown chat into a project: the warm session spawned without
    /// the project prompt is not reused — the next turn gets a new process
    /// with `--project-id` and no `--resume` of the old session.
    func testMoveToProjectRespawnsTheSessionWithTheProject() async throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        vm.send(text: "q1")
        let first = try lastFake()
        first.emit(.textDelta(turnID: "turn-1", text: "a1"))
        first.emit(.turnDone(turnID: "turn-1", status: .complete, sessionID: "sess-1"))
        let done = await waitForCondition { !vm.isStreaming && vm.thread.last?.message.status == "complete" }
        XCTAssertTrue(done)
        XCTAssertFalse(first.arguments.contains("--project-id"))

        let projectID = try XCTUnwrap(vm.createProject(name: "P"))
        vm.moveConversation(convID, toProject: projectID)
        XCTAssertEqual(vm.currentConversation?.projectID, projectID)
        XCTAssertNil(vm.currentConversation?.sessionID, "the old session never saw the project prompt")

        vm.send(text: "q2")
        // The replacement launches once the retired process has exited.
        let launched = await waitForCondition { self.fakes.count == 2 && self.fakes[1].turns.count == 1 }
        XCTAssertTrue(launched, "a new process for the project session")
        let second = try lastFake()
        XCTAssertEqual(second.arguments.firstIndex(of: "--project-id").map { second.arguments[$0 + 1] },
                       String(projectID))
        XCTAssertFalse(second.arguments.contains("--resume"))
        XCTAssertEqual(second.turns.last?.replay, true, "the fresh session replays the history")
    }

    /// Review M2: a move while a turn streams must not let the running
    /// session (spawned without the project) record its session id at
    /// `turn_done` — the next turn would `--resume` past the project prompt.
    func testMoveDuringAStreamingTurnIgnoresTheLateSessionID() async throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        vm.send(text: "q1")
        let first = try lastFake()
        first.emit(.textDelta(turnID: "turn-1", text: "a1"))
        _ = await waitForCondition { vm.liveTurn?.fullText == "a1" }

        let projectID = try XCTUnwrap(vm.createProject(name: "P"))
        vm.moveConversation(convID, toProject: projectID)
        first.emit(.turnDone(turnID: "turn-1", status: .complete, sessionID: "sess-late"))
        let done = await waitForCondition { !vm.isStreaming && vm.thread.last?.message.status == "complete" }
        XCTAssertTrue(done)

        let stored = try await dbManager.dbPool.read { d in
            try ChatConversationQueries.fetchByID(d, id: convID)
        }
        XCTAssertEqual(stored?.projectID, projectID)
        XCTAssertNil(stored?.sessionID, "the old-project session id is not recorded")
    }

    func testProjectDeletedClosesThePageAndDetachesTheShownChat() throws {
        let vm = try makeViewModel()
        let projectID = try XCTUnwrap(vm.createProject(name: "P"))
        vm.newConversation(projectID: projectID)
        vm.openProject(projectID)
        _ = try dbManager.dbPool.write { try ChatProjectQueries.delete($0, id: projectID) }
        vm.projectDeleted(projectID)
        XCTAssertNil(vm.openProjectID)
        XCTAssertTrue(vm.projects.isEmpty)
        XCTAssertNil(vm.currentConversation?.projectID)
    }
}

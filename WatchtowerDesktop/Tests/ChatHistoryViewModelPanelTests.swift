import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Chats panel's view model (spec 2026-10-26 §4–§6): its level, the
/// level's rows, the folded older group and the read mark on selection.
@MainActor
final class ChatHistoryViewModelLevelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        defaultsSuite = "ChatHistoryViewModelLevelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        defaults.removePersistentDomain(forName: defaultsSuite)
    }

    private func makeViewModel(_ manager: DatabaseManager? = nil) -> ChatHistoryViewModel {
        ChatHistoryViewModel(dbManager: manager ?? dbManager, attachmentsRoot: nil, defaults: defaults)
    }

    private func reloaded(_ vm: ChatHistoryViewModel) async {
        let done = expectation(description: "reload")
        vm.reloadRows { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
    }

    /// A chat with one owner message on its active path, `daysAgo` old.
    nonisolated private static func chat(
        _ d: Database, _ title: String, project: Int64? = nil, daysAgo: Double = 0
    ) throws -> Int64 {
        let at = Date().timeIntervalSince1970 - daysAgo * 86400
        let id = try TestDatabase.insertChatConversation(d, title: title, updatedAt: at)
        let msg = try TestDatabase.insertChatMessage(d, conversationID: id, role: "user", text: title, createdAt: at)
        try d.execute(sql: "UPDATE chat_conversations SET active_leaf_message_id = ?, project_id = ? WHERE id = ?",
                      arguments: [msg, project, id])
        return id
    }

    func testTheLevelIsRememberedPerWorkspace() async throws {
        let project = try await dbManager.dbPool.write { try ChatProjectQueries.create($0, name: "P").id }
        let first = makeViewModel()
        XCTAssertEqual(first.level, .all, "All chats by default")
        first.selectLevel(.project(project))
        XCTAssertEqual(makeViewModel().level, .project(project), "the next launch restores it")

        let (other, otherPath) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: otherPath) }
        XCTAssertEqual(makeViewModel(other).level, .all, "another workspace keeps its own")

        first.selectLevel(.all)
        XCTAssertEqual(makeViewModel().level, .all)
    }

    func testAGoneProjectFallsBackToAllChats() async throws {
        let (deleted, archived) = try await dbManager.dbPool.write { d in
            (try ChatProjectQueries.create(d, name: "D").id, try ChatProjectQueries.create(d, name: "A").id)
        }
        for project in [deleted, archived] {
            makeViewModel().selectLevel(.project(project))
            let vm = makeViewModel()
            await reloaded(vm)
            XCTAssertEqual(vm.level, .project(project), "still there")
        }
        try await dbManager.dbPool.write { d in
            _ = try ChatProjectQueries.delete(d, id: deleted)
            try d.execute(sql: "UPDATE chat_projects SET archived_at = 1 WHERE id = ?", arguments: [archived])
        }
        for project in [deleted, archived] {
            makeViewModel().selectLevel(.project(project))
            let vm = makeViewModel()
            XCTAssertEqual(vm.level, .project(project), "restored before the read")
            await reloaded(vm)
            XCTAssertEqual(vm.level, .all, "\(project) is gone")
            XCTAssertEqual(makeViewModel().level, .all, "and the fallback is remembered")
        }
    }

    /// A read started before the level changed may predate the project's
    /// row: it does not send the level back.
    func testAReadOlderThanTheLevelKeepsIt() async {
        let vm = makeViewModel()
        let done = expectation(description: "reload")
        vm.reloadRows { done.fulfill() }
        vm.selectLevel(.project(999))
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(vm.level, .project(999))
        await reloaded(vm)
        XCTAssertEqual(vm.level, .all, "a read after the change does")
    }

    func testRowsFollowTheLevel() async throws {
        let (projectA, projectB) = try await dbManager.dbPool.write { d in
            (try ChatProjectQueries.create(d, name: "A").id, try ChatProjectQueries.create(d, name: "B").id)
        }
        let (inA, inB, loose) = try await dbManager.dbPool.write { d in
            (try Self.chat(d, "a", project: projectA), try Self.chat(d, "b", project: projectB), try Self.chat(d, "c"))
        }
        let vm = makeViewModel()
        await reloaded(vm)
        XCTAssertEqual(Set(vm.rows.map(\.id)), [inA, inB, loose])
        vm.selectLevel(.project(projectA))
        XCTAssertEqual(vm.rows.map(\.id), [inA])
        XCTAssertEqual(vm.sections.flatMap(\.items).map(\.id), [inA])
        XCTAssertEqual(Set(vm.allRows.map(\.id)), [inA, inB, loose], "the switcher still counts every chat")
        vm.selectLevel(.all)
        XCTAssertEqual(vm.visibleRowIDs.count, 3)
    }

    func testTheOlderGroupFoldsAndIsRememberedPerLevel() async throws {
        let project = try await dbManager.dbPool.write { try ChatProjectQueries.create($0, name: "P").id }
        let (recent, old1, old2) = try await dbManager.dbPool.write { d in
            (try Self.chat(d, "new"), try Self.chat(d, "old1", daysAgo: 30), try Self.chat(d, "old2", daysAgo: 40))
        }
        let vm = makeViewModel()
        await reloaded(vm)
        XCTAssertEqual(vm.sections.map(\.kind), [.recent, .older])
        XCTAssertEqual(vm.sections.last?.items.map(\.id), [old1, old2], "the folded group still holds its rows")
        XCTAssertFalse(vm.olderExpanded, "folded by default")
        XCTAssertEqual(vm.visibleRowIDs, [recent])
        XCTAssertNil(vm.pinnedOlderRow)

        vm.selectedConversationID = old2
        XCTAssertEqual(vm.pinnedOlderRow?.id, old2, "the chat on screen shows under the folded header")
        XCTAssertEqual(vm.visibleRowIDs, [recent, old2])

        vm.olderExpanded = true
        XCTAssertNil(vm.pinnedOlderRow)
        XCTAssertEqual(vm.visibleRowIDs, [recent, old1, old2])
        XCTAssertTrue(makeViewModel().olderExpanded, "remembered for All chats")

        vm.selectLevel(.project(project))
        XCTAssertFalse(vm.olderExpanded, "a project has its own")
        vm.selectLevel(.all)
        XCTAssertTrue(vm.olderExpanded)
    }

    /// ↑/↓ walk the rows as shown: a folded older group is skipped.
    func testSelectAdjacentSkipsTheFoldedOlderGroup() async throws {
        let (recent, old) = try await dbManager.dbPool.write { d in
            (try Self.chat(d, "new"), try Self.chat(d, "old", daysAgo: 30))
        }
        let vm = makeViewModel()
        await reloaded(vm)
        XCTAssertTrue(vm.selectAdjacent(by: 1))
        XCTAssertEqual(vm.selectedConversationID, recent)
        XCTAssertFalse(vm.selectAdjacent(by: 1), "the folded group is not walked into")
        vm.olderExpanded = true
        XCTAssertTrue(vm.selectAdjacent(by: 1))
        XCTAssertEqual(vm.selectedConversationID, old)
    }

    func testSelectingAChatMarksItRead() async throws {
        let id = try await dbManager.dbPool.write { d in
            let id = try Self.chat(d, "q")
            let answer = try TestDatabase.insertChatMessage(d, conversationID: id, role: "assistant", text: "a")
            try d.execute(sql: "UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?",
                          arguments: [answer, id])
            return id
        }
        let vm = makeViewModel()
        await reloaded(vm)
        XCTAssertEqual(vm.rows.first.map(vm.state(of:)), .unread)
        vm.selectedConversationID = id
        await vm.writesSettled()
        XCTAssertEqual(vm.rows.first?.isUnread, false)
        XCTAssertEqual(vm.rows.first.map(vm.state(of:)), .read)
    }

    func testAnsweringIsReadLive() async throws {
        let id = try await dbManager.dbPool.write { try Self.chat($0, "q") }
        let vm = makeViewModel()
        await reloaded(vm)
        var running: Set<Int64> = []
        vm.isAnswering = { running.contains($0) }
        let row = try XCTUnwrap(vm.rows.first)
        XCTAssertEqual(vm.state(of: row), .read)
        running = [id]
        XCTAssertEqual(vm.state(of: row), .answering)
    }
}

/// The chat's two signals, as `AppState.wireActionStripRefresh` wires them
/// (spec §5.2): the action strip and the panel both re-read, and a turn that
/// ends on the chat on screen marks it read.
@MainActor
final class ChatHistoryViewModelTurnSignalTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var pool: ChatSessionPool!
    private var fakes: [FakeChatSessionProcess] = []
    private var turnCounter = 0
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var stripRefreshes = 0
    private var onScreen = true

    override func setUpWithError() throws {
        defaultsSuite = "ChatHistoryViewModelTurnSignalTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        fakes = []
        turnCounter = 0
        stripRefreshes = 0
        onScreen = true
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

    /// The main chat's pair wired exactly as AppState wires it.
    private func wiredPair() -> (ChatViewModel, ChatHistoryViewModel) {
        let vm = ChatViewModel(dbManager: dbManager, pool: pool, provider: .claude, defaults: defaults) { [weak self] in
            guard let self else { return UUID().uuidString }
            self.turnCounter += 1
            return "turn-\(self.turnCounter)"
        }
        let history = ChatHistoryViewModel(dbManager: dbManager, attachmentsRoot: nil, defaults: defaults)
        AppState.wireChat(vm, history: history)
        AppState.wireChatRefresh(
            vm, history: history,
            isChatOnScreen: { [weak self] in self?.onScreen ?? false },
            refreshActionStrip: { [weak self] in self?.stripRefreshes += 1 }
        )
        return (vm, history)
    }

    /// Opens a new chat, sends, and answers; returns once the turn ended.
    private func answeredTurn(_ vm: ChatViewModel, _ history: ChatHistoryViewModel) async throws -> Int64 {
        let created = await vm.newConversation()
        let id = try XCTUnwrap(created)
        history.selectedConversationID = id
        let sent = await vm.send(text: "q")
        XCTAssertTrue(sent)
        let fake = try XCTUnwrap(fakes.last)
        fake.emit(.textDelta(turnID: "turn-\(turnCounter)", text: "a"))
        fake.emit(.turnDone(turnID: "turn-\(turnCounter)", status: .complete, sessionID: nil))
        let done = await waitForCondition { !vm.isBusy && vm.thread.last?.message.status == "complete" }
        XCTAssertTrue(done)
        return id
    }

    func testATurnEndingOnTheChatOnScreenMarksItRead() async throws {
        let (vm, history) = wiredPair()
        let id = try await answeredTurn(vm, history)
        await history.writesSettled()
        let read = await waitForCondition {
            history.rows.first { $0.id == id }.map { $0.lastAnswerAt != nil && !$0.isUnread } == true
        }
        XCTAssertTrue(read, "answered and read")
        let stripped = await waitForCondition { self.stripRefreshes >= 1 }
        XCTAssertTrue(stripped, "the action strip still re-reads")
    }

    func testATurnEndingOffScreenLeavesTheChatUnread() async throws {
        onScreen = false
        let (vm, history) = wiredPair()
        let id = try await answeredTurn(vm, history)
        let unread = await waitForCondition { history.rows.first { $0.id == id }?.isUnread == true }
        XCTAssertTrue(unread, "the Chats tab was not on screen")
        await history.writesSettled()
        XCTAssertEqual(history.rows.first { $0.id == id }?.isUnread, true)
        XCTAssertGreaterThanOrEqual(stripRefreshes, 1)
    }

    func testATurnEndingOnAnotherChatLeavesItUnread() async throws {
        let (vm, history) = wiredPair()
        let created = await vm.newConversation()
        let id = try XCTUnwrap(created)
        let sent = await vm.send(text: "q")
        XCTAssertTrue(sent)
        vm.showLanding() // the owner left the chat while it answers
        let fake = try XCTUnwrap(fakes.last)
        fake.emit(.textDelta(turnID: "turn-\(turnCounter)", text: "a"))
        fake.emit(.turnDone(turnID: "turn-\(turnCounter)", status: .complete, sessionID: nil))
        let unread = await waitForCondition { history.rows.first { $0.id == id }?.isUnread == true }
        XCTAssertTrue(unread)
    }

    /// A proposal the session's MCP subprocess wrote is invisible to this
    /// process's observation; the action-awaited signal re-reads the panel
    /// and the strip both.
    func testAProposalWrittenElsewhereShowsAfterTheSignal() async throws {
        let (vm, history) = wiredPair()
        let created = await vm.newConversation()
        let id = try XCTUnwrap(created)
        let sent = await vm.send(text: "send it")
        XCTAssertTrue(sent)
        let loaded = await waitForCondition { history.rows.contains { $0.id == id } }
        XCTAssertTrue(loaded)
        XCTAssertEqual(history.rows.first { $0.id == id }?.pendingApprovals, 0)
        let before = stripRefreshes
        try TestDatabase.insertAgentActionSync(DatabasePool(path: dbPath), conversationID: id, turnID: "turn-1")
        let fake = try XCTUnwrap(fakes.last)
        fake.emit(.toolStart(ChatToolStart(turnID: "turn-1", id: "a", name: "mcp__claude_ai_Gmail__send", argsJSON: "{}")))
        fake.emit(.toolWait(ChatToolWait(turnID: "turn-1", id: "a", actionID: 1, message: "Waiting for your approval")))
        let shown = await waitForCondition { history.rows.first { $0.id == id }?.pendingApprovals == 1 }
        XCTAssertTrue(shown, "the panel re-read on the signal")
        let stripped = await waitForCondition { self.stripRefreshes > before }
        XCTAssertTrue(stripped, "and so did the action strip")
    }
}

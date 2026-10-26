import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Undo window's wait, held until the test ends it.
@MainActor
private final class ChatDeleteWindowGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var waits: [Duration] = []

    func wait(_ duration: Duration) async {
        waits.append(duration)
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Ends every wait started so far.
    func open() {
        let resumed = waiting
        waiting = []
        resumed.forEach { $0.resume() }
    }
}

/// The Chats panel's quick delete with Undo (spec 2026-10-26 §5.3): the
/// chat is hidden from every read at once, its DELETE (through the one
/// deletion path) runs when the window ends, another delete replaces it,
/// the panel leaves the screen or the app quits; Undo restores it.
@MainActor
final class PendingChatDeletesViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var gate: ChatDeleteWindowGate!
    private var forgotten: [Int64] = []
    private var answering: Set<Int64> = []

    override func setUpWithError() throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        defaultsSuite = "PendingChatDeletesViewModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        gate = ChatDeleteWindowGate()
        forgotten = []
        answering = []
    }

    override func tearDown() {
        gate.open()
        TestDatabase.cleanup(path: dbPath)
        defaults.removePersistentDomain(forName: defaultsSuite)
    }

    private func makeViewModel() async -> ChatHistoryViewModel {
        let vm = ChatHistoryViewModel(dbManager: dbManager, attachmentsRoot: nil, defaults: defaults)
        vm.deleteSleep = { [gate] in await gate?.wait($0) }
        vm.forgetConversation = { [weak self] in self?.forgotten.append($0) }
        vm.isAnswering = { [weak self] in self?.answering.contains($0) ?? false }
        await reloaded(vm)
        return vm
    }

    private func reloaded(_ vm: ChatHistoryViewModel) async {
        let done = expectation(description: "reload")
        vm.reloadRows { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
    }

    nonisolated private static func chat(_ d: Database, _ title: String, project: Int64? = nil) throws -> Int64 {
        let at = Date().timeIntervalSince1970
        let id = try TestDatabase.insertChatConversation(d, title: title, updatedAt: at)
        let msg = try TestDatabase.insertChatMessage(d, conversationID: id, role: "user", text: title, createdAt: at)
        try d.execute(sql: "UPDATE chat_conversations SET active_leaf_message_id = ?, project_id = ? WHERE id = ?",
                      arguments: [msg, project, id])
        return id
    }

    private func exists(_ id: Int64) async throws -> Bool {
        try await dbManager.dbPool.read { d in
            try Bool.fetchOne(d, sql: "SELECT EXISTS(SELECT 1 FROM chat_conversations WHERE id = ?)", arguments: [id]) ?? false
        }
    }

    // MARK: - Window

    func testTheDeleteWaitsForTheWindowThenCommitsThroughTheDeletePath() async throws {
        let (a, b) = try await dbManager.dbPool.write { d in (try Self.chat(d, "alpha"), try Self.chat(d, "beta")) }
        let vm = await makeViewModel()
        vm.now = { Date(timeIntervalSinceReferenceDate: 1_000) }

        XCTAssertTrue(vm.deleteWithUndo(a))
        XCTAssertEqual(vm.rows.map(\.id), [b], "hidden at once")
        XCTAssertEqual(vm.pendingDeleteToast, "Chat “alpha” deleted")
        XCTAssertEqual(vm.pendingDeletes.deadline, Date(timeIntervalSinceReferenceDate: 1_005))
        let settled1 = await waitForCondition { self.gate.waits == [.seconds(5)] }
        XCTAssertTrue(settled1, "the sessions panel's window")
        let stillThere = try await exists(a)
        XCTAssertTrue(stillThere, "nothing written inside the window")
        XCTAssertEqual(forgotten, [])

        gate.open()
        let settled2 = await waitForCondition { self.forgotten == [a] }
        XCTAssertTrue(settled2, "the session is retired at commit")
        let settled3 = await waitForCondition { vm.committingDeletes.isEmpty }
        XCTAssertTrue(settled3)
        let gone = try await exists(a)
        XCTAssertFalse(gone)
        XCTAssertNil(vm.pendingDeleteToast)
        await reloaded(vm)
        XCTAssertEqual(vm.rows.map(\.id), [b])
    }

    func testUndoRestoresTheChatAndTheWindowCommitsNothing() async throws {
        let a = try await dbManager.dbPool.write { try Self.chat($0, "alpha") }
        let vm = await makeViewModel()
        vm.deleteWithUndo(a)
        let settled4 = await waitForCondition { self.gate.waits.count == 1 }
        XCTAssertTrue(settled4)

        XCTAssertEqual(vm.undoPendingDelete(), a)
        XCTAssertEqual(vm.rows.map(\.id), [a])
        XCTAssertNil(vm.pendingDeleteToast)
        XCTAssertNil(vm.undoPendingDelete(), "nothing left to undo")
        gate.open()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))
        let stillThere = try await exists(a)
        XCTAssertTrue(stillThere)
        XCTAssertEqual(forgotten, [])
    }

    func testAnotherDeleteCommitsTheWaitingChatAndTakesTheBar() async throws {
        let (a, b, c) = try await dbManager.dbPool.write { d in
            (try Self.chat(d, "alpha"), try Self.chat(d, "beta"), try Self.chat(d, "gamma"))
        }
        let vm = await makeViewModel()
        vm.deleteWithUndo(a)
        vm.deleteWithUndo(b)
        XCTAssertEqual(vm.pendingDeleteToast, "Chat “beta” deleted")
        XCTAssertEqual(vm.rows.map(\.id), [c], "the committing one stays hidden")
        let settled5 = await waitForCondition { self.forgotten == [a] }
        XCTAssertTrue(settled5)
        let settled6 = await waitForCondition { vm.committingDeletes.isEmpty }
        XCTAssertTrue(settled6)
        let aGone = try await exists(a)
        let bThere = try await exists(b)
        XCTAssertFalse(aGone)
        XCTAssertTrue(bThere, "the new one waits for its own window")
        XCTAssertEqual(vm.undoPendingDelete(), b)
        XCTAssertEqual(Set(vm.rows.map(\.id)), [b, c])
    }

    /// Leaving the tab, a confirmed Delete… and the quit commit at once.
    func testCommitNowWritesTheDeleteBeforeTheWindowEnds() async throws {
        let a = try await dbManager.dbPool.write { try Self.chat($0, "alpha") }
        let vm = await makeViewModel()
        vm.deleteWithUndo(a)
        await vm.commitPendingDelete()
        XCTAssertEqual(forgotten, [a])
        let gone = try await exists(a)
        XCTAssertFalse(gone)
        XCTAssertNil(vm.pendingDeleteToast)
        XCTAssertTrue(vm.hiddenChatIDs.isEmpty)
        await vm.commitPendingDelete()
        XCTAssertEqual(forgotten, [a], "nothing pending: nothing more")
    }

    /// The quit path runs the chat's bounded commit beside the session deletes.
    func testTheQuitCommitsTheWaitingChat() throws {
        let source = try String(contentsOfFile: Self.sources + "/App/TrayAppDelegate.swift", encoding: .utf8)
        let step = try XCTUnwrap(source.range(of: "finishPendingDeletes: {"))
        let body = source[step.upperBound...].prefix(400)
        XCTAssertTrue(body.contains("Self.finishAllPendingDeletes("))
        XCTAssertTrue(body.contains("app.chatHistoryViewModel?.commitPendingDeleteForQuit()"))
        XCTAssertTrue(body.contains("await Self.finishPendingDeletes(app.workbenchesViewModel)"))
    }

    /// The chat's quit commit never holds the session commit back: the
    /// sessions' step starts while the chat's write is still running.
    func testTheQuitRunsTheChatCommitBesideTheSessionCommit() async throws {
        var events: [String] = []
        let chatGate = ChatDeleteWindowGate()
        await TrayAppDelegate.finishAllPendingDeletes(
            chats: {
                events.append("chat started")
                await chatGate.wait(.zero)
                events.append("chat done")
            },
            sessions: {
                events.append("sessions started")
                // The chat's write is under way while the sessions' runs.
                while !events.contains("chat started") { await Task.yield() }
                events.append("sessions done")
                chatGate.open()
            }
        )
        let sessionsDone = try XCTUnwrap(events.firstIndex(of: "sessions done"))
        let chatDone = try XCTUnwrap(events.firstIndex(of: "chat done"))
        XCTAssertLessThan(sessionsDone, chatDone, "the sessions' commit never waits for the chat's")
    }

    /// The quit waits for the chat's DELETE up to its bound, no longer.
    func testTheQuitCommitIsBounded() async throws {
        let (a, b) = try await dbManager.dbPool.write { d in (try Self.chat(d, "alpha"), try Self.chat(d, "beta")) }
        let vm = await makeViewModel()
        vm.deleteWithUndo(a)
        vm.quitDeleteSleep = { _ in try? await Task.sleep(for: .seconds(60)) }
        let finished = await vm.commitPendingDeleteForQuit(bound: .seconds(60))
        XCTAssertTrue(finished)
        let gone = try await exists(a)
        XCTAssertFalse(gone)

        vm.deleteWithUndo(b)
        // The bound passes at once: the DELETE has not landed by then.
        vm.quitDeleteSleep = { _ in }
        let timedOut = await vm.commitPendingDeleteForQuit(bound: .zero)
        XCTAssertFalse(timedOut, "the bound passed before the write")
        await vm.writesSettled()
    }

    // MARK: - Failure and busy

    /// A DELETE that fails is not silent: the panel says so and the chat
    /// is listed again.
    func testAFailedDeleteIsReportedAndTheChatComesBack() async throws {
        let a = try await dbManager.dbPool.write { try Self.chat($0, "alpha") }
        try await dbManager.dbPool.write { d in
            try d.execute(sql: """
                CREATE TRIGGER refuse_chat_delete BEFORE DELETE ON chat_conversations
                BEGIN SELECT RAISE(ABORT, 'refused'); END
                """)
        }
        let vm = await makeViewModel()
        vm.deleteWithUndo(a)
        await vm.commitPendingDelete()
        let stillThere = try await exists(a)
        XCTAssertTrue(stillThere)
        XCTAssertEqual(vm.lastError?.hasPrefix("Could not delete the chat"), true)
        XCTAssertTrue(vm.hiddenChatIDs.isEmpty)
        XCTAssertEqual(vm.rows.map(\.id), [a], "listed again")
    }

    /// A chat that started answering (or waiting) inside its Undo window is
    /// listed again at the commit, never deleted without the alert (CHAT-01).
    func testACommitOfAChatTurnedBusyRestoresIt() async throws {
        let (a, w) = try await dbManager.dbPool.write { d in (try Self.chat(d, "alpha"), try Self.chat(d, "waits")) }
        let vm = await makeViewModel()
        vm.deleteWithUndo(a)
        answering = [a]
        await vm.commitPendingDelete()
        var kept = try await exists(a)
        XCTAssertTrue(kept)
        XCTAssertTrue(forgotten.isEmpty, "its session is not retired")
        XCTAssertTrue(vm.hiddenChatIDs.isEmpty)
        XCTAssertTrue(vm.rows.contains { $0.id == a })

        vm.deleteWithUndo(w)
        try await dbManager.dbPool.write { d in
            try d.execute(sql: """
                INSERT INTO agent_actions (conversation_id, status, tool, args_json, created_at)
                VALUES (?, 'pending', 't', '{}', 0)
                """, arguments: [w])
        }
        await reloaded(vm)
        await vm.commitPendingDelete()
        kept = try await exists(w)
        XCTAssertTrue(kept, "waiting for approval: kept too")
        XCTAssertTrue(vm.rows.contains { $0.id == w })
    }

    private static var sources: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .standardizedFileURL.path
    }

    // MARK: - Hidden from every read

    func testAWaitingChatIsHiddenFromRowsSearchAndTheSwitcher() async throws {
        let project = try await dbManager.dbPool.write { try ChatProjectQueries.create($0, name: "P").id }
        let (a, b) = try await dbManager.dbPool.write { d in
            (try Self.chat(d, "alpha one", project: project), try Self.chat(d, "alpha two"))
        }
        try await dbManager.dbPool.write { d in
            // An unread answer on the project chat.
            let answer = try TestDatabase.insertChatMessage(
                d, conversationID: a, role: "assistant", text: "hi", createdAt: Date().timeIntervalSince1970 + 1
            )
            try d.execute(sql: "UPDATE chat_conversations SET active_leaf_message_id = ?, read_at = 0 WHERE id = ?",
                          arguments: [answer, a])
        }
        let vm = await makeViewModel()
        await vm.loadSwitcherSummaries()
        XCTAssertEqual(vm.switcherRows.first?.unreadCount, 1)

        vm.deleteWithUndo(a)
        XCTAssertEqual(vm.allRows.map(\.id), [b])
        XCTAssertEqual(vm.conversations.map(\.id), [b], "the landing's recents")
        XCTAssertFalse(vm.visibleRowIDs.contains(a))
        XCTAssertEqual(Set(vm.search("alpha").map(\.conversationID)), [b], "⌘K: neither its title nor its messages")
        await vm.loadSwitcherSummaries()
        XCTAssertEqual(vm.switcherRows.first?.unreadCount, 0, "the switcher's counts")

        vm.undoPendingDelete()
        XCTAssertEqual(Set(vm.search("alpha").map(\.conversationID)), [a, b])
    }

    // MARK: - The ✕ rule

    func testAnAnsweringOrWaitingChatIsNeverQuickDeleted() async throws {
        let (a, w) = try await dbManager.dbPool.write { d in (try Self.chat(d, "answering"), try Self.chat(d, "waiting")) }
        try await dbManager.dbPool.write { d in
            try d.execute(sql: """
                INSERT INTO agent_actions (conversation_id, status, tool, args_json, created_at)
                VALUES (?, 'pending', 't', '{}', 0)
                """, arguments: [w])
        }
        answering = [a]
        let vm = await makeViewModel()
        for id in [a, w] {
            let row = try XCTUnwrap(vm.rows.first { $0.id == id })
            XCTAssertFalse(vm.isQuickDelete(row))
            XCTAssertFalse(vm.deleteWithUndo(id), "the caller asks first")
        }
        XCTAssertNil(vm.pendingDeleteToast)
        XCTAssertEqual(Set(vm.rows.map(\.id)), [a, w])

        answering = []
        XCTAssertTrue(vm.deleteWithUndo(a), "re-read live: no longer answering")
    }
}

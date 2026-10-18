import GRDB
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Board #670 phase 2b-2: the main chat while its writes await the writer —
/// held by `HeldWriter`, as a busy database would.
@MainActor
final class ChatViewModelAsyncWriteTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var pool: ChatSessionPool!
    private var fakes: [FakeChatSessionProcess] = []
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        defaultsSuite = "ChatViewModelAsyncWriteTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        fakes = []
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

    private func makeViewModel() throws -> ChatViewModel {
        ChatViewModel(dbManager: dbManager, pool: pool, provider: .claude, defaults: defaults) { "turn-1" }
    }

    private func lastFake() throws -> FakeChatSessionProcess {
        try XCTUnwrap(fakes.last)
    }

    /// Board #670: a turn whose end is being written cannot be stopped, so
    /// no composer (the main chat's, the ⌘/ popup's) offers Stop meanwhile;
    /// it does again for the next turn.
    func testStopIsNotOfferedWhileATurnsEndIsWritten() async throws {
        let vm = try makeViewModel()
        _ = await vm.newConversation()
        await vm.send(text: "q")
        let fake = try lastFake()
        fake.emit(.textDelta(turnID: "turn-1", text: "answer"))
        _ = await waitForCondition { vm.liveTurn?.fullText == "answer" }
        XCTAssertTrue(vm.canStop, "a running turn can be stopped")
        let held = HeldWriter(dbManager.dbPool)
        defer { held.release() }

        fake.emit(.turnDone(turnID: "turn-1", status: .complete, sessionID: nil))
        let finishing = await waitForCondition { vm.isFinishingTurn }
        XCTAssertTrue(finishing)
        XCTAssertFalse(vm.canStop, "nothing could stop it now")
        XCTAssertTrue(vm.isBusy, "and no next send meanwhile")
        held.release()
        await vm.writesSettled()
        XCTAssertFalse(vm.isFinishingTurn)
        XCTAssertTrue(vm.canStop)
    }

    /// Board #670: a send waits for a file dropped just before it. When the
    /// owner opens another chat meanwhile, nothing goes out — A's text is
    /// never sent into B — and A keeps its stored file for its next message.
    func testASendWaitingForAFileSendsNothingWhenTheChatChangedMeanwhile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-files-\(UUID().uuidString)")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("notes".utf8).write(to: file)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: file)
        }
        let vm = ChatViewModel(dbManager: dbManager, pool: pool, provider: .claude, defaults: defaults,
                               attachmentsRoot: root) { "turn-1" }
        let first = await vm.newConversation()
        let chatA = try XCTUnwrap(first)
        let second = await vm.newConversation()
        let chatB = try XCTUnwrap(second)
        vm.select(conversationID: chatA)
        vm.draft = "for A only"
        let held = HeldWriter(dbManager.dbPool)
        defer { held.release() }

        vm.attachFiles([file])
        XCTAssertEqual(vm.composerAttachments.importing, [file.lastPathComponent], "shown as being stored")
        let sending = Task { await vm.sendDraft() }
        let waiting = await eventually { vm.isWaitingForAttachments }
        XCTAssertTrue(waiting, "the composer says the send waits")
        vm.select(conversationID: chatB)
        held.release()
        await sending.value

        XCTAssertTrue(fakes.flatMap(\.turns).isEmpty, "nothing was sent")
        let userRows = try await dbManager.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_messages WHERE role = 'user'") ?? 0
        }
        XCTAssertEqual(userRows, 0)
        XCTAssertEqual(vm.draft, "for A only", "the text stays where the switch left it, as on main")
        vm.select(conversationID: chatA)
        XCTAssertEqual(vm.composerAttachments.pending.map(\.name), [file.lastPathComponent])
    }
}

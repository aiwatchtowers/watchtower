import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The assistant tab container of one target: the tab list, the active tab, and
/// the per-tab chat view models it keeps alive across switches.
@MainActor
final class TargetAssistantViewModelTests: XCTestCase {
    // MARK: - Fixtures

    /// The chat tables are Desktop-owned (`DatabaseManager` creates them at
    /// runtime), and the shared test schema does not carry them — the container
    /// needs them for real, so they are created here.
    private func makeManager() throws -> (DatabaseManager, String) {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        try manager.dbPool.write { db in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
        }
        return (manager, path)
    }

    private func makeTarget(_ manager: DatabaseManager, text: String = "ship feature") throws -> Target {
        let id = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: text, intent: "x",
                                     periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        return try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) })
    }

    private func makeContainer(
        _ manager: DatabaseManager,
        target: Target,
        aiService: @escaping @autoclosure () -> any AIServiceProtocol = MockClaudeService()
    ) -> TargetAssistantViewModel {
        let targets = TargetsViewModel(dbManager: manager)
        return TargetAssistantViewModel(
            target: target,
            viewModel: targets,
            dbManager: manager
        ) { conversationID in
            TargetChatViewModel(
                target: target, viewModel: targets, dbManager: manager,
                conversationID: conversationID, aiService: aiService()
            )
        }
    }

    private func conversationRows(_ manager: DatabaseManager, target: Target) throws -> [ChatConversation] {
        try manager.dbPool.read { db in
            try ChatConversationQueries.fetchAllByContext(db, type: "target", id: String(target.id))
        }
    }

    private func waitForStreamEnd(_ chat: TargetChatViewModel, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while chat.isStreaming {
            if Date() > deadline {
                XCTFail("stream did not finish within \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Opening

    /// A target chatted with for the first time gets exactly one tab, created
    /// lazily right here — the pre-tabs behaviour.
    func testFirstOpenCreatesASingleTab() throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)

        let assistant = makeContainer(manager, target: target)

        XCTAssertEqual(assistant.conversations.count, 1)
        XCTAssertEqual(assistant.activeConversationID, assistant.conversations.first?.id)
        XCTAssertNotNil(assistant.activeChat)
        XCTAssertEqual(try conversationRows(manager, target: target).count, 1)
        XCTAssertNil(assistant.errorMessage)
    }

    /// A target that already had the single pre-tabs conversation must adopt it
    /// as tab #1 rather than starting a second, empty thread beside it.
    func testAdoptsTheExistingConversationInsteadOfCreatingOne() throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let existing = try manager.dbPool.write { db in
            try ChatConversationQueries.create(
                db, title: "Task: ship feature", contextType: "target", contextID: String(target.id)
            )
        }
        try manager.dbPool.write { db in
            try ChatMessageQueries.insert(db, conversationID: existing.id, role: "user", text: "hello")
        }

        let assistant = makeContainer(manager, target: target)

        XCTAssertEqual(assistant.conversations.map(\.id), [existing.id])
        XCTAssertEqual(assistant.activeConversationID, existing.id)
        XCTAssertEqual(assistant.activeChat?.messages.count, 1)
        XCTAssertEqual(try conversationRows(manager, target: target).count, 1)
    }

    /// With several tabs the container opens on the one the user last worked in
    /// — the row the pre-tabs `fetchByContext` would have returned.
    func testOpensOnTheMostRecentlyUsedTab() throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let first = try manager.dbPool.write { db in
            try ChatConversationQueries.create(
                db, title: "one", contextType: "target", contextID: String(target.id)
            )
        }
        let second = try manager.dbPool.write { db in
            try ChatConversationQueries.create(
                db, title: "two", contextType: "target", contextID: String(target.id)
            )
        }
        // Make the older tab the most recently touched one.
        try manager.dbPool.write { db in try ChatConversationQueries.touch(db, id: first.id) }

        let assistant = makeContainer(manager, target: target)

        XCTAssertEqual(assistant.conversations.map(\.id), [first.id, second.id],
                       "tab order stays creation order")
        XCTAssertEqual(assistant.activeConversationID, first.id)
    }

    // MARK: - Create / switch

    func testNewConversationOpensAndActivatesAnotherTab() throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let assistant = makeContainer(manager, target: target)
        let firstID = try XCTUnwrap(assistant.activeConversationID)

        let newID = try XCTUnwrap(assistant.newConversation())

        XCTAssertEqual(assistant.conversations.map(\.id), [firstID, newID])
        XCTAssertEqual(assistant.activeConversationID, newID)
        XCTAssertEqual(assistant.conversations.last?.title, TargetAssistantViewModel.newChatTitle)
        XCTAssertEqual(try conversationRows(manager, target: target).count, 2)
    }

    /// Switching tabs must hand back the SAME view model, never a fresh one —
    /// that is what lets a turn keep running in the tab you left.
    func testSwitchingTabsKeepsTheSameChatViewModels() throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let assistant = makeContainer(manager, target: target)
        let firstID = try XCTUnwrap(assistant.activeConversationID)
        let firstChat = try XCTUnwrap(assistant.activeChat)

        let secondID = try XCTUnwrap(assistant.newConversation())
        let secondChat = try XCTUnwrap(assistant.activeChat)
        XCTAssertFalse(firstChat === secondChat)

        assistant.select(firstID)
        XCTAssertTrue(assistant.activeChat === firstChat)
        assistant.select(secondID)
        XCTAssertTrue(assistant.activeChat === secondChat)
    }

    func testSelectingAnUnknownConversationIsIgnored() throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let assistant = makeContainer(manager, target: target)
        let activeID = assistant.activeConversationID

        assistant.select(9_999)

        XCTAssertEqual(assistant.activeConversationID, activeID)
    }

    // MARK: - Rename

    func testRenameUpdatesTheTabAndTheRow() throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let assistant = makeContainer(manager, target: target)
        let id = try XCTUnwrap(assistant.activeConversationID)

        assistant.rename(id, to: "  Rollout plan  ")

        XCTAssertEqual(assistant.conversations.first?.title, "Rollout plan")
        let stored = try manager.dbPool.read { db in try ChatConversationQueries.fetchByID(db, id: id) }
        XCTAssertEqual(stored?.title, "Rollout plan")
    }

    func testRenameToBlankIsIgnored() throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let assistant = makeContainer(manager, target: target)
        let id = try XCTUnwrap(assistant.activeConversationID)
        let before = assistant.conversations.first?.title

        assistant.rename(id, to: "   ")

        XCTAssertEqual(assistant.conversations.first?.title, before)
    }

    // MARK: - Close

    func testCloseDeletesTheConversationAndItsMessages() throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let assistant = makeContainer(manager, target: target)
        let firstID = try XCTUnwrap(assistant.activeConversationID)
        let secondID = try XCTUnwrap(assistant.newConversation())
        try manager.dbPool.write { db in
            try ChatMessageQueries.insert(db, conversationID: secondID, role: "user", text: "hi")
        }

        assistant.close(secondID)

        XCTAssertEqual(assistant.conversations.map(\.id), [firstID])
        XCTAssertEqual(assistant.activeConversationID, firstID)
        XCTAssertNotNil(assistant.activeChat)
        XCTAssertNil(assistant.loadedChat(secondID))
        let rows = try conversationRows(manager, target: target)
        XCTAssertEqual(rows.map(\.id), [firstID])
        let messages = try manager.dbPool.read { db in
            try ChatMessageQueries.fetchByConversation(db, conversationID: secondID)
        }
        XCTAssertTrue(messages.isEmpty, "closing a tab must not leave orphaned messages")
    }

    /// Closing a tab that is not the active one leaves the selection alone.
    func testClosingABackgroundTabKeepsTheActiveOne() throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let assistant = makeContainer(manager, target: target)
        let firstID = try XCTUnwrap(assistant.activeConversationID)
        let secondID = try XCTUnwrap(assistant.newConversation())
        let secondChat = try XCTUnwrap(assistant.activeChat)

        assistant.close(firstID)

        XCTAssertEqual(assistant.conversations.map(\.id), [secondID])
        XCTAssertEqual(assistant.activeConversationID, secondID)
        XCTAssertTrue(assistant.activeChat === secondChat)
    }

    /// A target always keeps one assistant thread — the last tab has no Close.
    func testLastTabCannotBeClosed() throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let assistant = makeContainer(manager, target: target)
        let onlyID = try XCTUnwrap(assistant.activeConversationID)

        assistant.close(onlyID)

        XCTAssertEqual(assistant.conversations.map(\.id), [onlyID])
        XCTAssertEqual(assistant.activeConversationID, onlyID)
        XCTAssertEqual(try conversationRows(manager, target: target).count, 1)
    }

    // MARK: - Chat activity (the next-step badge's input)

    /// The production chain behind the staleness badge: opening the Assistant tab
    /// creates a conversation row, and that alone must NOT read as activity —
    /// otherwise every first visit lights "context changed since this step" on a
    /// target nobody has chatted with. A real turn does.
    func testOpeningATabIsNotActivityButASentTurnIs() throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)

        let assistant = makeContainer(manager, target: target)
        XCTAssertEqual(assistant.conversations.count, 1, "the tab row exists")
        var activity = try manager.dbPool.read { db in
            try ChatConversationQueries.latestTurnActivity(db, type: "target", id: String(target.id))
        }
        XCTAssertNil(activity, "opening a tab is not work on the target")

        _ = assistant.newConversation()
        activity = try manager.dbPool.read { db in
            try ChatConversationQueries.latestTurnActivity(db, type: "target", id: String(target.id))
        }
        XCTAssertNil(activity, "neither is opening another one")

        let chat = try XCTUnwrap(assistant.activeChat)
        chat.inputText = "what is left here?"
        chat.send()

        activity = try manager.dbPool.read { db in
            try ChatConversationQueries.latestTurnActivity(db, type: "target", id: String(target.id))
        }
        XCTAssertNotNil(activity, "a user turn is activity even before any reply lands")
    }

    // MARK: - Failed reads

    /// A read that fails is "unknown", not "this target has no chats": falling
    /// through to the create would open a duplicate tab beside the existing ones.
    /// The chat tables are missing here, so the list read throws.
    func testAFailedTabListReadNeverOpensAReplacementTab() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)

        let assistant = makeContainer(manager, target: target)

        XCTAssertTrue(assistant.conversations.isEmpty)
        XCTAssertNil(assistant.activeChat)
        XCTAssertNil(assistant.activeConversationID)
        let message = try XCTUnwrap(assistant.errorMessage)
        XCTAssertTrue(message.hasPrefix("Failed to load chats"),
                      "the load must report the read, not a follow-up write: \(message)")
    }

    // MARK: - Background streaming

    /// The whole point of the container owning the VMs: a turn started in one
    /// tab keeps running — and lands its reply — while the user reads another.
    func testStreamInABackgroundTabKeepsRunningAcrossASwitch() async throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let assistant = makeContainer(
            manager, target: target,
            aiService: MockClaudeService(events: [.sessionID("s1"), .text("background reply"), .done])
        )
        let firstID = try XCTUnwrap(assistant.activeConversationID)
        let workingID = try XCTUnwrap(assistant.newConversation())
        let workingChat = try XCTUnwrap(assistant.activeChat)

        workingChat.inputText = "dig through the channel"
        workingChat.send()
        XCTAssertTrue(workingChat.isStreaming)
        XCTAssertTrue(assistant.isWorking(workingID))
        XCTAssertTrue(assistant.isAnyWorking)

        // Switch away mid-turn.
        assistant.select(firstID)
        XCTAssertFalse(assistant.activeChat === workingChat)
        XCTAssertTrue(assistant.isWorking(workingID), "the background tab's chip stays lit")

        try await waitForStreamEnd(workingChat)

        XCTAssertTrue(assistant.loadedChat(workingID) === workingChat, "the VM survived the switch")
        XCTAssertTrue(workingChat.messages.contains { $0.role == .assistant && $0.text == "background reply" })
        XCTAssertFalse(assistant.isWorking(workingID))
        XCTAssertFalse(assistant.isAnyWorking)
    }

    /// Closing a tab mid-turn cancels the stream FIRST: cancelling persists the
    /// partial reply, and that write has to land while the conversation still
    /// exists so the delete takes it along. Deleting first would leave the row
    /// orphaned (or fail), exactly what the explicit message delete guards
    /// against.
    func testClosingAStreamingTabLeavesNoOrphanedMessage() throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let assistant = makeContainer(manager, target: target)
        _ = try XCTUnwrap(assistant.activeConversationID)
        let secondID = try XCTUnwrap(assistant.newConversation())
        let chat = try XCTUnwrap(assistant.activeChat)

        // Mid-turn state: an assistant placeholder carrying partial text.
        chat.messages.append(ChatMessage(
            id: UUID(), role: .assistant, text: "half a repl", timestamp: Date(), isStreaming: true
        ))
        chat.isStreaming = true

        assistant.close(secondID)

        XCTAssertFalse(chat.isStreaming)
        let leftovers = try manager.dbPool.read { db in
            try ChatMessageQueries.fetchByConversation(db, conversationID: secondID)
        }
        XCTAssertTrue(leftovers.isEmpty, "the cancelled turn's partial reply must not outlive the tab")
    }

    // MARK: - Auto-title

    func testNewTabIsAutoTitledFromItsFirstUserMessage() throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let assistant = makeContainer(manager, target: target)
        let newID = try XCTUnwrap(assistant.newConversation())
        let chat = try XCTUnwrap(assistant.activeChat)

        chat.inputText = "Draft the rollout note for the release"
        chat.send()

        let title = try XCTUnwrap(assistant.conversations.last?.title)
        XCTAssertEqual(title, "Draft the rollout note for the…")
        let stored = try manager.dbPool.read { db in try ChatConversationQueries.fetchByID(db, id: newID) }
        XCTAssertEqual(stored?.title, title)
    }

    /// Only the FIRST message names the tab; later ones leave the title alone.
    func testAutoTitleOnlyAppliesToAStillUnnamedTab() throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let assistant = makeContainer(manager, target: target)
        _ = assistant.newConversation()
        let chat = try XCTUnwrap(assistant.activeChat)

        chat.inputText = "first"
        chat.send()
        chat.inputText = "second"
        chat.send()

        XCTAssertEqual(assistant.conversations.last?.title, "first")
    }

    /// Tab #1 carries the task title — a message there must not rename it.
    func testFirstTabKeepsItsTaskTitle() throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let assistant = makeContainer(manager, target: target)
        let chat = try XCTUnwrap(assistant.activeChat)

        chat.inputText = "what should I do first?"
        chat.send()

        XCTAssertEqual(assistant.conversations.first?.title, "Task: ship feature")
    }

    func testAutoTitleCollapsesWhitespaceAndCaps() {
        XCTAssertEqual(TargetAssistantViewModel.autoTitle(from: "  hello\n  world  "), "hello world")
        XCTAssertEqual(
            TargetAssistantViewModel.autoTitle(from: String(repeating: "a", count: 40)),
            String(repeating: "a", count: 30) + "…"
        )
        XCTAssertTrue(TargetAssistantViewModel.isPlaceholderTitle(""))
        XCTAssertTrue(TargetAssistantViewModel.isPlaceholderTitle(TargetAssistantViewModel.newChatTitle))
        XCTAssertFalse(TargetAssistantViewModel.isPlaceholderTitle("Rollout plan"))
    }

    // MARK: - Target activity

    /// The host screen's next-step badge hangs off this callback, so it must be
    /// wired on every tab the container owns — not just the first.
    func testTargetActivityIsForwardedFromEveryTab() throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let assistant = makeContainer(manager, target: target)
        var notifications = 0
        assistant.onTargetActivity = { notifications += 1 }

        _ = assistant.newConversation()
        let chat = try XCTUnwrap(assistant.activeChat)
        let action = ProposedAction(type: .updateStatus, reason: "done", status: "done")
        let card = TargetActionCard(messageID: UUID(), action: action, state: .pending)
        chat.actionCards = [card]
        chat.approve(card)

        XCTAssertEqual(notifications, 1)
    }
}

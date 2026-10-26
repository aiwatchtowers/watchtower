import GRDB
import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Chats panel's header and project switcher (spec 2026-10-26 §4):
/// `All chats ⌄` + `+`, `‹ 📁 <name> ⌄` + `+`, the popover's rows, New
/// Project… and All Chats, and the Project overview row at a project.
@MainActor
final class ChatProjectSwitcherViewTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var pool: ChatSessionPool!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        defaultsSuite = "ChatProjectSwitcherViewTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        pool = ChatSessionPool(
            dbPool: dbManager.dbPool,
            processFactory: { FakeChatSessionProcess(arguments: $0) },
            closeGrace: .milliseconds(20)
        )
    }

    override func tearDown() async throws {
        await pool.closeAll()
        TestDatabase.cleanup(path: dbPath)
        defaults.removePersistentDomain(forName: defaultsSuite)
    }

    /// A project with one answered chat in it; returns (project, chat).
    private func project(_ name: String, unread: Bool = false) async throws -> (Int64, Int64) {
        try await dbManager.dbPool.write { d in
            let projectID = try ChatProjectQueries.create(d, name: name).id
            let id = try TestDatabase.insertChatConversation(d, title: "\(name) chat")
            let msg = try TestDatabase.insertChatMessage(d, conversationID: id, role: "assistant", text: "answer")
            try d.execute(
                sql: "UPDATE chat_conversations SET active_leaf_message_id = ?, project_id = ?, read_at = ? WHERE id = ?",
                arguments: [msg, projectID, unread ? nil : Date().addingTimeInterval(3600).timeIntervalSince1970, id]
            )
            return (projectID, id)
        }
    }

    private func history() async -> ChatHistoryViewModel {
        let history = ChatHistoryViewModel(dbManager: dbManager, attachmentsRoot: nil, defaults: defaults)
        let done = expectation(description: "load")
        history.reloadRows { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        return history
    }

    private final class Calls {
        var newChat = 0, newProject = 0, showAll = 0
        var selected: [Int64] = []
    }

    private func actions(_ calls: Calls) -> ChatPanelHeaderActions {
        ChatPanelHeaderActions(
            newChat: { calls.newChat += 1 },
            selectProject: { calls.selected.append($0) },
            newProject: { calls.newProject += 1 },
            showAll: { calls.showAll += 1 }
        )
    }

    // MARK: - Header

    func testAllChatsHeaderHasTheSwitcherAndPlusButNoBack() async throws {
        let history = await history()
        let calls = Calls()
        let header = ChatPanelHeader(historyVM: history, projectName: nil, actions: actions(calls))

        let button = try header.inspect().find(ChatProjectSwitcherButton.self)
        XCTAssertNoThrow(try button.find(text: "All chats"))
        XCTAssertThrowsError(try button.find(ViewType.Image.self) { try $0.actualImage().name() == "folder" })
        XCTAssertThrowsError(try header.inspect().find(viewWithAccessibilityLabel: "Back to All Chats"))
        try header.inspect().find(viewWithAccessibilityLabel: "New chat").find(ViewType.Button.self).tap()
        XCTAssertEqual(calls.newChat, 1)
    }

    func testProjectHeaderHasBackTheFolderNameAndPlus() async throws {
        let history = await history()
        let calls = Calls()
        let header = ChatPanelHeader(historyVM: history, projectName: "acme", actions: actions(calls))

        let button = try header.inspect().find(ChatProjectSwitcherButton.self)
        XCTAssertNoThrow(try button.find(text: "acme"))
        XCTAssertNoThrow(try button.find(ViewType.Image.self) { try $0.actualImage().name() == "folder" })
        try header.inspect().find(viewWithAccessibilityLabel: "Back to All Chats").find(ViewType.Button.self).tap()
        XCTAssertEqual(calls.showAll, 1)
        try header.inspect().find(viewWithAccessibilityLabel: "New chat").find(ViewType.Button.self).tap()
        XCTAssertEqual(calls.newChat, 1)
    }

    // MARK: - Panel levels

    /// No PROJECTS section and no New chat row at either level; the Project
    /// overview row only at a project, where only its chats are listed.
    func testPanelLevelsListTheirRows() async throws {
        let (acme, _) = try await project("acme")
        _ = try await project("beta")
        let chatVM = ChatViewModel(dbManager: dbManager, pool: pool, defaults: defaults)
        chatVM.reloadProjects()
        let history = await history()
        let sidebar = ChatSidebarView(historyVM: history, chatVM: chatVM, onNewChat: {}, onArchive: { _ in }, onDelete: { _ in })

        XCTAssertNoThrow(try sidebar.inspect().find(text: "acme chat"))
        XCTAssertNoThrow(try sidebar.inspect().find(text: "beta chat"))
        for absent in ["PROJECTS", "New chat", "Project overview"] {
            XCTAssertThrowsError(try sidebar.inspect().find(text: absent), absent)
        }

        history.selectLevel(.project(acme))
        XCTAssertNoThrow(try sidebar.inspect().find(text: "Project overview"))
        XCTAssertNoThrow(try sidebar.inspect().find(text: "acme chat"))
        XCTAssertThrowsError(try sidebar.inspect().find(text: "beta chat"))
        XCTAssertNoThrow(try sidebar.inspect().find(ChatProjectSwitcherButton.self).find(text: "acme"))
    }

    /// The header's `‹` goes back to All chats; a click on Project overview
    /// opens the project page and clears the history selection.
    func testBackAndProjectOverviewDriveTheViewModels() async throws {
        let (acme, chat) = try await project("acme")
        let chatVM = ChatViewModel(dbManager: dbManager, pool: pool, defaults: defaults)
        chatVM.reloadProjects()
        let history = await history()
        history.selectLevel(.project(acme))
        history.selectedConversationID = chat
        let sidebar = ChatSidebarView(historyVM: history, chatVM: chatVM, onNewChat: {}, onArchive: { _ in }, onDelete: { _ in })

        try sidebar.inspect().find(text: "Project overview").find(ViewType.Label.self, relation: .parent).callOnTapGesture()
        XCTAssertEqual(chatVM.openProjectID, acme)
        XCTAssertNil(history.selectedConversationID)

        try sidebar.inspect().find(viewWithAccessibilityLabel: "Back to All Chats").find(ViewType.Button.self).tap()
        XCTAssertEqual(history.level, .all)
    }

    // MARK: - Popover

    /// RECENT lists the projects, latest activity first, the current one
    /// checked, each with its state: unread answers, answering chats (live),
    /// else the age. New Project… and All Chats call their actions.
    func testPopoverListsProjectsWithStateAndItsActions() async throws {
        let (acme, acmeChat) = try await project("acme", unread: true)
        let (beta, _) = try await project("beta")
        try await dbManager.dbPool.write { d in
            try d.execute(sql: "UPDATE chat_conversations SET updated_at = 1 WHERE project_id = ?", arguments: [beta])
            try d.execute(sql: "UPDATE chat_projects SET updated_at = 1 WHERE id = ?", arguments: [beta])
        }
        let history = await history()
        history.isAnswering = { $0 == acmeChat }
        await history.loadSwitcherSummaries()
        XCTAssertNil(history.switcherError)
        XCTAssertEqual(history.switcherRows.map(\.id), [acme, beta])

        var picked: [Int64] = []
        var newProject = 0, showAll = 0
        let popover = ChatProjectSwitcherPopover(
            historyVM: history, currentID: acme,
            onSelect: { picked.append($0) }, onNewProject: { newProject += 1 }, onShowAll: { showAll += 1 }
        )

        let rows = try popover.inspect().findAll(SwitcherPopoverRow.self).map { try $0.actualView() }
        XCTAssertEqual(rows.map(\.name), ["acme", "beta"])
        XCTAssertEqual(rows.map(\.isCurrent), [true, false])
        XCTAssertEqual(rows[0].segments, [
            SwitcherSegment(text: "1 new answer", tone: .badge),
            SwitcherSegment(text: "1 answering", tone: .secondary)
        ])
        XCTAssertEqual(rows[1].segments.map(\.tone), [.secondary], "no state: the age")
        XCTAssertNoThrow(try popover.inspect().find(text: "RECENT"))

        try popover.inspect().findAll(SwitcherPopoverRow.self)[1].find(ViewType.Button.self).tap()
        XCTAssertEqual(picked, [beta])
        try popover.inspect().find(button: "New Project…").tap()
        XCTAssertEqual(newProject, 1)
        try popover.inspect().find(button: "All Chats").tap()
        XCTAssertEqual(showAll, 1)
    }

    /// At All chats no project is checked.
    func testPopoverAtAllChatsChecksNothing() async throws {
        _ = try await project("acme")
        let history = await history()
        await history.loadSwitcherSummaries()
        let popover = ChatProjectSwitcherPopover(
            historyVM: history, currentID: nil, onSelect: { _ in }, onNewProject: {}, onShowAll: {}
        )
        let rows = try popover.inspect().findAll(SwitcherPopoverRow.self).map { try $0.actualView() }
        XCTAssertEqual(rows.map(\.isCurrent), [false])
    }
}

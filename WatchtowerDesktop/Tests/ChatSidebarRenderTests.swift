import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The AI Chat history reads as the Workbench sessions panel does (PR #84's
/// model): the panel in its own colour, the conversation on the detail
/// backdrop, and the chat — or project page — on screen is a tab that runs
/// on into the conversation across the panel's edge line.
@MainActor
final class ChatSidebarRenderTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var pool: ChatSessionPool!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    private static let size = NSSize(width: 900, height: 500)
    private let probe = ViewRenderProbe(size: size)

    override func setUpWithError() throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        defaultsSuite = "ChatSidebarRenderTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        // The history column is opt-in; the split reads it from here.
        defaults.set(true, forKey: "chat.historyVisible")
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

    /// A conversation with one message on its active path.
    nonisolated private static func answered(_ d: Database, title: String) throws -> Int64 {
        let id = try TestDatabase.insertChatConversation(d, title: title)
        let msg = try TestDatabase.insertChatMessage(d, conversationID: id, role: "user", text: title)
        try d.execute(sql: "UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?", arguments: [msg, id])
        return id
    }

    private func loadedHistory() async -> ChatHistoryViewModel {
        let history = ChatHistoryViewModel(dbManager: dbManager, attachmentsRoot: nil)
        let done = expectation(description: "load")
        history.load { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        return history
    }

    private func split(_ chatVM: ChatViewModel, _ history: ChatHistoryViewModel) -> some View {
        let appState = AppState.isolated()
        appState.databaseManager = dbManager
        return ChatSplitView(chatVM: chatVM, historyVM: history)
            .environment(appState)
            .defaultAppStorage(defaults)
    }

    /// The selected chat covers the panel's edge line at its row; another
    /// row, the project row and the space below the list keep it. Right of
    /// the panel the conversation paints the detail backdrop.
    func testSelectedChatTabCoversThePanelEdgeLine() async throws {
        let ids = try await dbManager.dbPool.write { d in
            try ["first", "second", "third"].map { try Self.answered(d, title: $0) }
        }
        try await dbManager.dbPool.write { d in _ = try ChatProjectQueries.create(d, name: "acme") }
        let chatVM = ChatViewModel(dbManager: dbManager, pool: pool, defaults: defaults)
        chatVM.reloadProjects()
        let history = await loadedHistory()
        // The middle row of three (the newest is listed first).
        XCTAssertEqual(history.sections.flatMap(\.conversations).map(\.id).count, 3)
        let selected = history.sections.flatMap(\.conversations)[1].id
        XCTAssertEqual(selected, ids[1])
        history.selectedConversationID = selected
        chatVM.select(conversationID: selected)

        for name in [NSAppearance.Name.darkAqua, .aqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let detail = try probe.pixel(probe.render(Color.clear.detailBackground(), appearance), x: 450, y: 250)
            XCTAssertEqual(detail.alpha, 255, "an empty capture would compare equal to another one")
            let page = try probe.render(split(chatVM, history), appearance)
            let edge = Int(ChatSplitView.historyWidth) - 1
            let line = try probe.pixel(page, x: edge, y: 450)
            XCTAssertNotEqual(line, detail, "\(name): the edge line shows below the list")
            // Rows under the "Chats" header: PROJECTS, acme, TODAY, then the
            // chats (the newest first), about 26pt apart.
            XCTAssertEqual(try probe.pixel(page, x: edge, y: Rows.second), detail, "\(name): the selected tab covers the line")
            XCTAssertEqual(try probe.pixel(page, x: edge, y: Rows.first), line, "\(name): another chat keeps the line")
            XCTAssertEqual(try probe.pixel(page, x: edge, y: Rows.project), line, "\(name): the closed project keeps the line")
            // Beside the tab, the conversation's backdrop.
            XCTAssertEqual(try probe.pixel(page, x: edge + 2, y: Rows.second), detail, "\(name): the conversation beside the tab")
            XCTAssertEqual(try probe.pixel(page, x: 600, y: 300), detail, "\(name): the conversation")
        }
    }

    /// The open project page is the tab: its row covers the line.
    func testOpenProjectTabCoversThePanelEdgeLine() async throws {
        _ = try await dbManager.dbPool.write { d in try Self.answered(d, title: "first") }
        let projectID = try await dbManager.dbPool.write { d in try ChatProjectQueries.create(d, name: "acme").id }
        let chatVM = ChatViewModel(dbManager: dbManager, pool: pool, defaults: defaults)
        chatVM.reloadProjects()
        chatVM.openProject(projectID)
        let history = await loadedHistory()

        for name in [NSAppearance.Name.darkAqua, .aqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let detail = try probe.pixel(probe.render(Color.clear.detailBackground(), appearance), x: 450, y: 250)
            let page = try probe.render(split(chatVM, history), appearance)
            let edge = Int(ChatSplitView.historyWidth) - 1
            let line = try probe.pixel(page, x: edge, y: 450)
            XCTAssertNotEqual(line, detail, "\(name): the edge line shows below the list")
            XCTAssertEqual(try probe.pixel(page, x: edge, y: Rows.project), detail, "\(name): the open project covers the line")
            XCTAssertEqual(try probe.pixel(page, x: edge, y: Rows.first), line, "\(name): the chat row keeps the line")
        }
    }

    /// Row centres (y, in points) in the history column.
    private enum Rows {
        static let project = 73
        static let first = 127
        static let second = 153
    }
}

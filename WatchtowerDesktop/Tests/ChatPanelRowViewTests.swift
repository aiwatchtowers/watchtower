import AppKit
import GRDB
import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Chats panel's rows and groups (spec 2026-10-26 §5.1, §5.2, §6): the
/// state dot's colour per state, the unread title's weight, the second
/// line, the "▸ N older" header folded and open, and the chat on screen
/// pinned under a folded header.
@MainActor
final class ChatPanelRowViewTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var pool: ChatSessionPool!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        defaultsSuite = "ChatPanelRowViewTests.\(UUID().uuidString)"
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

    /// An answered chat `daysAgo` old; read unless `unread`, with a pending
    /// proposal of `pendingTool`.
    @discardableResult
    private func chat(
        _ title: String, daysAgo: Double = 0, unread: Bool = false, pendingTool: String? = nil
    ) async throws -> Int64 {
        try await dbManager.dbPool.write { d in
            let at = Date().addingTimeInterval(-daysAgo * 86_400).timeIntervalSince1970
            let id = try TestDatabase.insertChatConversation(d, title: title, updatedAt: at)
            let msg = try TestDatabase.insertChatMessage(
                d, conversationID: id, role: "assistant", text: "\(title) answer", createdAt: at)
            try d.execute(
                sql: "UPDATE chat_conversations SET active_leaf_message_id = ?, read_at = ? WHERE id = ?",
                arguments: [msg, unread ? nil : at + 1, id]
            )
            if let pendingTool { try TestDatabase.insertAgentAction(d, tool: pendingTool, conversationID: id) }
            return id
        }
    }

    private func history() async -> ChatHistoryViewModel {
        let history = ChatHistoryViewModel(dbManager: dbManager, attachmentsRoot: nil, defaults: defaults)
        let done = expectation(description: "load")
        history.reloadRows { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        return history
    }

    private func sidebar(_ history: ChatHistoryViewModel) -> ChatSidebarView {
        let chatVM = ChatViewModel(dbManager: dbManager, pool: pool, defaults: defaults)
        return ChatSidebarView(historyVM: history, chatVM: chatVM, onNewChat: {}, onArchive: { _ in }, onDelete: { _ in })
    }

    private func row(_ history: ChatHistoryViewModel, _ id: Int64) throws -> ChatPanelRow {
        try XCTUnwrap(history.rows.first { $0.id == id })
    }

    // MARK: - Dot

    /// The dot's centre: orange while waiting, the accent while answering
    /// or unread, the backdrop through a read chat's ring.
    func testDotColourPerState() throws {
        let probe = ViewRenderProbe(size: NSSize(width: 16, height: 16))
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        func centre(_ view: some View) throws -> ViewRenderProbe.RGBA {
            try probe.pixel(probe.render(view.frame(width: 16, height: 16).background(Color.white), appearance), x: 8, y: 8)
        }
        let accent = try centre(Rectangle().fill(Color.accentColor))
        let orange = try centre(Rectangle().fill(Tone.warning))
        let white = try centre(Color.clear)

        XCTAssertEqual(try centre(ChatStateDot(state: .waitingForApproval)), orange, "waiting: orange")
        XCTAssertEqual(try centre(ChatStateDot(state: .unread)), accent, "unread: the accent")
        let answering = try centre(ChatStateDot(state: .answering))
        XCTAssertNotEqual(answering, white, "answering: a filled dot")
        XCTAssertNotEqual(answering, orange, "answering: not the waiting colour")
        XCTAssertEqual(try centre(ChatStateDot(state: .read)), white, "read: a hollow ring")
        XCTAssertNotEqual(accent, orange)
    }

    // MARK: - Row

    /// The title is semibold while unread and regular once read; the second
    /// line is the state's text, coloured while it names the state.
    func testRowTitleWeightAndSecondLine() async throws {
        let unread = try await chat("unread one", unread: true)
        let read = try await chat("read one")
        let waiting = try await chat("waiting one", pendingTool: "create_target")
        let answering = try await chat("answering one")
        let history = await history()
        history.isAnswering = { $0 == answering }

        func view(_ id: Int64) throws -> ChatPanelRowView<EmptyView> {
            let row = try row(history, id)
            let state = history.state(of: row)
            return ChatPanelRowView(row: row, state: state, secondLine: state.secondLine(for: row, now: Date(), showsProject: true))
        }

        let unreadTitle = try view(unread).inspect().find(text: "unread one")
        XCTAssertEqual(try unreadTitle.attributes().fontWeight(), .semibold)
        let readTitle = try view(read).inspect().find(text: "read one")
        XCTAssertEqual(try readTitle.attributes().fontWeight(), .regular)

        XCTAssertEqual(history.state(of: try row(history, waiting)), .waitingForApproval)
        let waitingLine = try view(waiting).inspect().find(ViewType.Text.self) {
            try $0.string().hasPrefix("Waiting for approval: ")
        }
        XCTAssertEqual(try waitingLine.attributes().foregroundColor(), Tone.warning)
        let answeringLine = try view(answering).inspect().find(text: "Answering…")
        XCTAssertEqual(try answeringLine.attributes().foregroundColor(), .accentColor)
        XCTAssertNoThrow(try view(read).inspect().find(ViewType.Text.self) { try $0.string().hasPrefix("read one answer · ") })
    }

    /// A pending proposal outranks a live turn: the row waits for the owner.
    func testWaitingOutranksAnsweringInTheRow() async throws {
        let id = try await chat("blocked", pendingTool: "create_target")
        let history = await history()
        history.isAnswering = { $0 == id }
        let row = try row(history, id)
        let state = history.state(of: row)
        XCTAssertEqual(state, .waitingForApproval)
        let view = ChatPanelRowView(row: row, state: state, secondLine: state.secondLine(for: row, now: Date(), showsProject: true))
        XCTAssertThrowsError(try view.inspect().find(text: "Answering…"))
        XCTAssertEqual(try view.inspect().find(ChatStateDot.self).actualView().state, .waitingForApproval)
    }

    // MARK: - Groups

    /// Folded, the older group is its header "▸ N older" only; a click opens
    /// it (its chats listed, remembered by the view model) and folds it again.
    func testOlderGroupFoldsAndOpens() async throws {
        try await chat("recent one")
        for title in ["old a", "old b", "old c"] { try await chat(title, daysAgo: 30) }
        let history = await history()
        let sidebar = sidebar(history)

        XCTAssertNoThrow(try sidebar.inspect().find(text: "RECENT"))
        let header = try sidebar.inspect().find(PanelFoldHeader.self)
        XCTAssertEqual(try header.actualView().count, 3)
        XCTAssertNoThrow(try header.find(text: "3 older"))
        XCTAssertNoThrow(try header.find(ViewType.Image.self) { try $0.actualImage().name() == "chevron.right" })
        XCTAssertNoThrow(try sidebar.inspect().find(text: "recent one"))
        for title in ["old a", "old b", "old c"] {
            XCTAssertThrowsError(try sidebar.inspect().find(text: title), "\(title) folded away")
        }

        try header.find(ViewType.Button.self).tap()
        XCTAssertTrue(history.olderExpanded)
        let open = try sidebar.inspect().find(PanelFoldHeader.self)
        XCTAssertNoThrow(try open.find(ViewType.Image.self) { try $0.actualImage().name() == "chevron.down" })
        for title in ["old a", "old b", "old c"] {
            XCTAssertNoThrow(try sidebar.inspect().find(text: title), "\(title) listed")
        }

        try open.find(ViewType.Button.self).tap()
        XCTAssertFalse(history.olderExpanded)
    }

    /// The chat on screen that lives in the folded group shows pinned under
    /// the header; the group's other chats stay folded.
    func testChatOnScreenIsPinnedUnderTheFoldedHeader() async throws {
        try await chat("old a", daysAgo: 30)
        let shown = try await chat("old b", daysAgo: 40)
        try await chat("old c", daysAgo: 50)
        let history = await history()
        history.selectedConversationID = shown
        let sidebar = sidebar(history)

        XCTAssertFalse(history.olderExpanded)
        XCTAssertNoThrow(try sidebar.inspect().find(text: "3 older"))
        XCTAssertNoThrow(try sidebar.inspect().find(text: "old b"), "the chat on screen is pinned")
        XCTAssertThrowsError(try sidebar.inspect().find(text: "old a"))
        XCTAssertThrowsError(try sidebar.inspect().find(text: "old c"))
        XCTAssertEqual(history.visibleRowIDs, [shown])
    }

    /// In All chats a project chat's second line names its project; at the
    /// project's own level it does not.
    func testProjectNamePrefixOnlyInAllChats() async throws {
        let id = try await chat("planning")
        let projectID = try await dbManager.dbPool.write { d -> Int64 in
            let projectID = try ChatProjectQueries.create(d, name: "acme").id
            try d.execute(sql: "UPDATE chat_conversations SET project_id = ? WHERE id = ?", arguments: [projectID, id])
            return projectID
        }
        let history = await history()
        let sidebar = sidebar(history)
        XCTAssertNoThrow(try sidebar.inspect().find(ViewType.Text.self) { try $0.string().hasPrefix("acme · planning answer · ") })

        history.selectLevel(.project(projectID))
        XCTAssertNoThrow(try sidebar.inspect().find(ViewType.Text.self) { try $0.string().hasPrefix("planning answer · ") })
        XCTAssertThrowsError(try sidebar.inspect().find(ViewType.Text.self) { try $0.string().hasPrefix("acme · ") })
    }
}

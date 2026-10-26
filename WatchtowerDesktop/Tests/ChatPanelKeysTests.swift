import XCTest
import GRDB
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Chats panel's keyboard (spec 2026-10-26 §5.4): the cursor over the
/// rows shown, ⌘1…⌘9 over the same order, and the View-menu context.
@MainActor
final class ChatPanelKeysTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        defaultsSuite = "ChatPanelKeysTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        defaults.removePersistentDomain(forName: defaultsSuite)
    }

    private struct Fixture {
        let vm: ChatHistoryViewModel
        let a: Int64, b: Int64, c: Int64, old: Int64
    }

    /// Three recent chats (newest first: c, b, a) and one 30 days old.
    private func fixture() async throws -> Fixture {
        let ids = try await dbManager.dbPool.write { d -> [Int64] in
            try [("a", 3.0), ("b", 2.0), ("c", 1.0), ("old", 30 * 86_400.0)].map { title, ago in
                let at = Date().timeIntervalSince1970 - ago
                let id = try TestDatabase.insertChatConversation(d, title: title, updatedAt: at)
                let msg = try TestDatabase.insertChatMessage(d, conversationID: id, role: "user", text: title, createdAt: at)
                try d.execute(sql: "UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?", arguments: [msg, id])
                return id
            }
        }
        let vm = ChatHistoryViewModel(dbManager: dbManager, attachmentsRoot: nil, defaults: defaults)
        vm.deleteSleep = { _ in try? await Task.sleep(for: .seconds(60)) }
        let done = expectation(description: "reload")
        vm.reloadRows { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        return Fixture(vm: vm, a: ids[0], b: ids[1], c: ids[2], old: ids[3])
    }

    func testTheCursorStartsOnTheChatOnScreenElseTheFirstRow() async throws {
        let fixture = try await fixture()
        let vm = fixture.vm
        let a = fixture.a
        let c = fixture.c
        vm.enterPanelKeyboard()
        XCTAssertEqual(vm.panelCursor, c, "the first row")
        vm.panelCursor = nil
        vm.selectedConversationID = a
        vm.enterPanelKeyboard()
        XCTAssertEqual(vm.panelCursor, a, "the chat on screen")
        vm.selectedConversationID = c
        vm.enterPanelKeyboard()
        XCTAssertEqual(vm.panelCursor, a, "a cursor still shown stays")
    }

    /// ↑/↓ move only the highlight, over the rows shown (the folded older
    /// group skipped), clamped at both ends.
    func testTheCursorMovesWithoutOpeningAndSkipsTheFoldedGroup() async throws {
        let fixture = try await fixture()
        let vm = fixture.vm
        let a = fixture.a
        let b = fixture.b
        let c = fixture.c
        let old = fixture.old
        XCTAssertEqual(vm.visibleRowIDs, [c, b, a])
        vm.movePanelCursor(-1)
        XCTAssertEqual(vm.panelCursor, a, "↑ with no cursor: the last row")
        vm.movePanelCursor(1)
        XCTAssertEqual(vm.panelCursor, a, "clamped at the end")
        vm.movePanelCursor(-1)
        vm.movePanelCursor(-1)
        vm.movePanelCursor(-1)
        XCTAssertEqual(vm.panelCursor, c)
        XCTAssertNil(vm.selectedConversationID, "moving opens nothing")
        vm.olderExpanded = true
        vm.panelCursor = a
        vm.movePanelCursor(1)
        XCTAssertEqual(vm.panelCursor, old, "an open group is walked")
        XCTAssertEqual(vm.listedPanelCursor, old)
        vm.olderExpanded = false
        XCTAssertNil(vm.listedPanelCursor, "a cursor in the folded group is not shown")
    }

    func testADeleteMovesTheCursorToTheNeighbour() async throws {
        let fixture = try await fixture()
        let vm = fixture.vm
        let a = fixture.a
        let b = fixture.b
        let c = fixture.c
        vm.panelCursor = b
        XCTAssertTrue(vm.deleteWithUndo(b))
        XCTAssertEqual(vm.panelCursor, a, "the next row")
        XCTAssertTrue(vm.deleteWithUndo(a))
        XCTAssertEqual(vm.panelCursor, c, "the last row: the one before it")
    }

    func testShortcutsNumberTheRowsShown() async throws {
        let fixture = try await fixture()
        let vm = fixture.vm
        let a = fixture.a
        let b = fixture.b
        let c = fixture.c
        let old = fixture.old
        XCTAssertEqual([1, 2, 3].map { vm.rowID(atShortcut: $0) }, [c, b, a])
        XCTAssertNil(vm.rowID(atShortcut: 4), "the folded older group is not numbered")
        XCTAssertNil(vm.rowID(atShortcut: 0))
        vm.olderExpanded = true
        XCTAssertEqual(vm.rowID(atShortcut: 4), old)
        vm.deleteWithUndo(c)
        XCTAssertEqual(vm.rowID(atShortcut: 1), b, "a chat waiting in the Undo bar is not numbered")
    }

    func testTheMenuContextOpensTheNthRowAndKnowsTheLevel() async throws {
        let fixture = try await fixture()
        let vm = fixture.vm
        let b = fixture.b
        var opened: [Int64] = []
        let context = ChatsMenuContext(historyVM: vm) { opened.append($0) }
        XCTAssertTrue(context.canUseRowKeys)
        XCTAssertEqual(context.shortcutState, .init(canUseRowKeys: true, projectSelected: false))
        context.open(atShortcut: 2)
        context.open(atShortcut: 9)
        XCTAssertEqual(opened, [b], "past the end: nothing")

        let taken = ChatsMenuContext(historyVM: vm, keysTaken: true) { _ in }
        XCTAssertFalse(taken.canUseRowKeys)

        let project = try await dbManager.dbPool.write { try ChatProjectQueries.create($0, name: "P").id }
        vm.selectLevel(.project(project))
        XCTAssertEqual(context.shortcutState, .init(canUseRowKeys: true, projectSelected: true))
        XCTAssertEqual(
            ItemShortcutTarget.resolve(workbench: nil, chats: context.shortcutState).back, .showAllChats
        )
    }

    /// ⌘1…⌘9 and ⌘[ act on the panel only while it is visible (ask #660):
    /// hidden, the context resolves to neither — even inside a project.
    func testAHiddenPanelTakesNeitherTheRowKeysNorBack() async throws {
        let fixture = try await fixture()
        let vm = fixture.vm
        let project = try await dbManager.dbPool.write { try ChatProjectQueries.create($0, name: "P").id }
        vm.selectLevel(.project(project))
        let hidden = ChatsMenuContext(historyVM: vm, panelVisible: false) { _ in }
        XCTAssertFalse(hidden.canUseRowKeys)
        XCTAssertEqual(
            ItemShortcutTarget.resolve(workbench: nil, chats: hidden.shortcutState),
            .init(items: nil, back: nil)
        )
        let shown = ChatsMenuContext(historyVM: vm, panelVisible: true) { _ in }
        XCTAssertEqual(
            ItemShortcutTarget.resolve(workbench: nil, chats: shown.shortcutState),
            .init(items: .chatRows, back: .showAllChats)
        )
    }

    /// The Undo bar under the list: the chat's name, and Undo brings it
    /// back and hands the panel the keyboard (where ⌘Z does the same).
    func testTheUndoBarNamesTheChatAndRestoresIt() async throws {
        let fixture = try await fixture()
        let vm = fixture.vm
        let c = fixture.c
        XCTAssertThrowsError(try ChatDeleteToast(historyVM: vm).inspect().find(ViewType.Button.self), "no bar")
        vm.deleteWithUndo(c)
        let bar = ChatDeleteToast(historyVM: vm)
        XCTAssertNoThrow(try bar.inspect().find(text: "Chat “c” deleted"))
        let serial = vm.panelKeyboardSerial
        try bar.inspect().find(button: "Undo ⌘Z").tap()
        XCTAssertEqual(vm.visibleRowIDs.first, c)
        XCTAssertNil(vm.pendingDeleteToast)
        XCTAssertEqual(vm.panelKeyboardSerial, serial + 1)
    }

    /// One set of ⌘1…⌘9 and one ⌘[, in the View menu (spec §4, §5.4):
    /// the Workbench menu no longer binds them.
    func testTheItemChordsAreBoundOnceInTheSharedMenu() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .standardizedFileURL.path
        let workbench = try String(contentsOfFile: root + "/App/WorkbenchCommands.swift", encoding: .utf8)
        XCTAssertFalse(workbench.contains("KeyEquivalent(Character(String(n)))"))
        XCTAssertFalse(workbench.contains(#".keyboardShortcut("[""#))
        let shared = try String(contentsOfFile: root + "/App/ItemShortcutCommands.swift", encoding: .utf8)
        XCTAssertTrue(shared.contains("CommandGroup(after: .toolbar)"))
        XCTAssertTrue(shared.contains(#"Menu("Go to Item")"#))
        XCTAssertTrue(shared.contains(#"Button("Back")"#))
        let app = try String(contentsOfFile: root + "/App/WatchtowerApp.swift", encoding: .utf8)
        XCTAssertTrue(app.contains("ItemShortcutCommands()"))
    }
}

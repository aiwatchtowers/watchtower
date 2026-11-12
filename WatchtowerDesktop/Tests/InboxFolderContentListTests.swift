import GRDB
import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Inbox list column (spec "The list"): urgency sections in order, the
/// Earlier line into the brief's History, the search's no-match line that
/// never moves the selection, and Needs approval's stack — a header per
/// group, **Approve All N…** only where the allowlist offers it, each
/// header at the group row's id.
@MainActor
final class InboxFolderContentListTests: XCTestCase {
    private var paths: [String] = []
    private var suites: [String] = []

    override func tearDown() async throws {
        paths.forEach { TestDatabase.cleanup(path: $0) }
        suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        paths = []
        suites = []
    }

    private static func row(_ id: String, _ title: String, kind: InboxRowKind = .threads) -> InboxFolderListRow {
        InboxFolderListRow(id: id, content: InboxRowContent(kind: kind, title: title))
    }

    // MARK: - Sections and the Earlier line

    func testSectionsDrawInOrder() throws {
        let content = InboxFolderListContent(folderKind: .root, folderTitle: "Inbox", sections: [
            InboxListSection(id: "needsYou", title: "Needs you", rows: [
                Self.row("wait", "Waiting for me", kind: .peopleWaiting), Self.row("mail", "Mail waiting")
            ]),
            InboxListSection(id: "today", title: "Today", rows: [Self.row("day:2026-11-12", "Morning brief")]),
            InboxListSection(id: "running", title: "Running", rows: [Self.row("tracks", "Track my threads")])
        ])
        let list = InboxFolderContentList(content: content)
        let inspected = try list.inspect()
        XCTAssertEqual(inspected.findAll(ViewType.Section.self).count, 3)
        XCTAssertEqual(try inspected.findAll(InboxListSectionHeading.self).map { try $0.actualView().title },
                       ["Needs you", "Today", "Running"])
        XCTAssertEqual(try inspected.findAll(InboxListRow.self).map { try $0.actualView().content.title },
                       ["Waiting for me", "Mail waiting", "Morning brief", "Track my threads"])
        XCTAssertThrowsError(try inspected.find(InboxEarlierLineRow.self), "no Earlier line given")

        let approvals = InboxFolderListContent(folderKind: .approvals, folderTitle: "Needs approval", sections: [
            InboxListSection(id: "tracksToCreate", title: "Tracks to create",
                             rows: [Self.row("group:tracksToCreate", "Create 4 tracks", kind: .approval)], count: 4)
        ])
        let heading = try InboxFolderContentList(content: approvals).inspect().find(InboxListSectionHeading.self)
        XCTAssertEqual(try heading.actualView().count, 4, "a group's heading shows its approvals")
        XCTAssertNoThrow(try heading.find(text: "4"))
    }

    func testEarlierLineOpensHistory() throws {
        var opened = 0
        let content = InboxFolderListContent(
            folderKind: .root, folderTitle: "Inbox",
            sections: [InboxListSection(id: "today", title: "Today", rows: [Self.row("day:x", "Morning brief")])],
            earlierLine: InboxEarlierLine(pastThisMonth: 5, notOpened: 2))
        let onEarlier = { opened += 1 }
        let list = InboxFolderContentList(content: content, onEarlier: onEarlier)
        let earlier = try list.inspect().find(InboxEarlierLineRow.self)
        XCTAssertNoThrow(try earlier.find(text: "Past briefs are inside Morning brief · 5 this month, 2 not opened"))
        try earlier.find(ViewType.Button.self).tap()
        XCTAssertEqual(opened, 1)
    }

    /// A search with no match shows the no-match line; a read meanwhile and
    /// clearing the search leave the selection where it was.
    func testNoMatchKeepsSelection() async throws {
        let (pool, path) = try TestDatabase.createPool()
        paths.append(path)
        let suite = "InboxFolderContentListTests.\(UUID().uuidString)"
        suites.append(suite)
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        let today = HomeFeedBuilder.dayString(noon, calendar: .current)
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_folders (kind, parent_id, slug, title, position) VALUES ('root', NULL, 'inbox', 'Inbox', 0)
                """)
            try db.execute(sql: """
                INSERT INTO inbox_folders (kind, parent_id, slug, title, position)
                VALUES ('approvals', ?, 'needs-approval', 'Needs approval', 0)
                """, arguments: [db.lastInsertedRowID])
            try db.execute(sql: "INSERT INTO inbox_folder_state (id, revision) VALUES (1, 1)")
            _ = try TestDatabase.insertSlackAccount(db, currentUserID: "1:U001")
            try TestDatabase.insertBriefing(db, userID: "1:U001", date: today)
        }
        let vm = ActionStripViewModel(
            dbPool: pool, cliRunner: FakeCLIRunner(), defaults: try XCTUnwrap(UserDefaults(suiteName: suite)),
            clock: { noon }, dayChangeSignals: [])
        await vm.refresh()
        let brief = "day:\(today)"
        XCTAssertEqual(vm.entrySelection, brief)
        let rowsBefore = vm.folderList.rows.map(\.id)

        vm.listQuery = "  no such thing  "
        XCTAssertTrue(vm.folderList.hasNoMatches)
        XCTAssertNil(vm.folderList.earlierLine, "no Earlier line while searching")
        let list = InboxFolderContentList(content: vm.folderList)
        XCTAssertNoThrow(try list.inspect().find(text: "No matches for “no such thing”"))
        XCTAssertThrowsError(try list.inspect().find(viewWithAccessibilityIdentifier: "inbox.emptyFolder"))

        await vm.refresh()
        XCTAssertEqual(vm.entrySelection, brief, "a read under a search keeps the hidden selection")

        vm.listQuery = ""
        XCTAssertEqual(vm.folderList.rows.map(\.id), rowsBefore)
        XCTAssertEqual(vm.entrySelection, brief)
        XCTAssertEqual(vm.folderList.selection, brief)
        XCTAssertFalse(vm.folderList.hasNoMatches)
    }

    // MARK: - Needs approval's stack

    private static func action(_ id: Int64, tool: String) -> InboxFolderEntry {
        .approval(NeedsApprovalItem(.action(AgentAction(row: Row([
            "id": id, "tool": tool, "args_json": "{}", "status": "pending", "surface": "main", "reason": "r",
            "context_type": "", "created_at": "2026-11-06T09:0\(id % 10):00Z"
        ])))))
    }

    /// Three `create_track`, three Slack sends and three connector calls,
    /// every one open.
    private static func stack() -> [NeedsApprovalStackSection] {
        let entries = (1...3).map { action($0, tool: "create_track") }
            + (4...6).map { action($0, tool: "send_slack_message") }
            + (7...9).map { action($0, tool: ConnectorCallProposal.tool) }
        return NeedsApprovalGroups.stack(entries, openActions: Set(1...9))
    }

    private static func pane(
        _ sections: [NeedsApprovalStackSection], scrollTarget: String? = nil
    ) -> NeedsApprovalPane<Text> {
        NeedsApprovalPane(
            sections: sections, note: nil, scrollTarget: scrollTarget,
            approveAllModel: { _ in InboxBulkPressModel() },
            card: { entry in Text(entry.id) })
    }

    func testApproveAllOnlyOnEligibleGroups() throws {
        let sections = Self.stack()
        XCTAssertEqual(sections.map(\.group), [.tracksToCreate, .messages, .other])
        let headers = try Self.pane(sections).inspect().findAll(NeedsApprovalGroupHeader.self)
        XCTAssertEqual(try headers.map { try $0.actualView().title }, ["Tracks to create", "Messages", "Other"])
        XCTAssertEqual(try headers.map { try $0.actualView().count }, [3, 3, 3])

        let tracks = try headers[0].find(InboxBulkPressButton.self).actualView()
        XCTAssertEqual(tracks.title, "Approve All 3…")
        XCTAssertEqual(tracks.confirmTitle(3), "Approve All 3")
        XCTAssertThrowsError(try headers[1].find(InboxBulkPressButton.self), "never for Slack sends")
        XCTAssertThrowsError(try headers[2].find(InboxBulkPressButton.self), "never for connector calls")
    }

    func testGroupRowScrollsToItsHeader() throws {
        let sections = Self.stack()
        let groupRow = NeedsApprovalGroups.rowID(.tracksToCreate)
        // The list's group row and the stack's header share one id.
        XCTAssertEqual(sections.first?.id, groupRow)
        let pane = Self.pane(sections, scrollTarget: groupRow)
        let header = try pane.inspect().find(viewWithId: groupRow)
        XCTAssertEqual(try header.find(NeedsApprovalGroupHeader.self).actualView().title, "Tracks to create")
        XCTAssertNoThrow(try pane.inspect().find(viewWithId: "approval:action:1"), "cards keep their own ids")
        XCTAssertEqual(pane.scrollTarget, groupRow)
    }
}

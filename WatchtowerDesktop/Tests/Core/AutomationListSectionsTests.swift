import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

final class AutomationListSectionsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(
        id: Int64,
        name: String,
        workbenchID: Int64? = nil,
        enabled: Bool = true,
        confirmed: Bool = true,
        parseError: String = "",
        disabledReason: String = ""
    ) -> AutomationListItem {
        let automation = Automation(
            id: id, slug: "a\(id)", scope: workbenchID == nil ? .personal : .workbench, projectID: workbenchID,
            name: name, approvalHash: "h2", confirmedHash: confirmed ? "h2" : "h1", parseError: parseError,
            enabled: enabled, disabledReason: disabledReason
        )
        return AutomationListItem(
            automation: automation, lastRun: nil, activeRun: nil, tokens7d: 0,
            badges: AutomationListItem.badges(for: automation, grants: []),
            triggerText: AutomationTriggerText.describe(kind: automation.triggerKind, specJSON: automation.triggerSpecJSON)
        )
    }

    private func draft(_ id: Int64, name: String, workbenchID: Int64? = nil) -> AutomationDraftRow {
        AutomationDraftRow(conversationID: id, contextID: "d\(id)", workbenchID: workbenchID, name: name,
                           updatedAt: now)
    }

    // MARK: - Sections

    func testSectionsPersonalThenWorkbenchesWithDraftsFirst() {
        let sections = AutomationListSections.make(
            items: [item(id: 1, name: "Mail digest"), item(id: 2, name: "Standup"),
                    item(id: 3, name: "Release notes", workbenchID: 3)],
            drafts: [draft(10, name: "Deploy check", workbenchID: 3)],
            workbenches: [(id: 4, name: "zeta"), (id: 3, name: "acme")],
            query: ""
        )
        XCTAssertEqual(sections.map(\.title), ["Personal", "acme"])
        XCTAssertEqual(sections.map(\.count), [2, 2])
        XCTAssertEqual(sections[1].drafts.map(\.conversationID), [10])
        XCTAssertEqual(sections[1].items.map(\.id), [3])
        XCTAssertEqual(sections[0].items.map(\.id), [1, 2])
    }

    func testQueryFiltersItemsAndDraftsAndDropsEmptySections() {
        let sections = AutomationListSections.make(
            items: [item(id: 1, name: "Mail digest"), item(id: 2, name: "Standup"),
                    item(id: 3, name: "Release notes", workbenchID: 3)],
            drafts: [draft(10, name: "Mail rules"), draft(11, name: "Deploy check", workbenchID: 3)],
            workbenches: [(id: 3, name: "acme")],
            query: "  mail "
        )
        XCTAssertEqual(sections.map(\.title), ["Personal"])
        XCTAssertEqual(sections[0].items.map(\.id), [1])
        XCTAssertEqual(sections[0].drafts.map(\.conversationID), [10])
        XCTAssertEqual(sections[0].count, 2)
    }

    // MARK: - Rows

    func testChips() {
        XCTAssertEqual(AutomationRowPresentation.chips(item(id: 1, name: "a", confirmed: false)), [.needsConfirmation])
        XCTAssertEqual(AutomationRowPresentation.chips(
            item(id: 1, name: "a", enabled: false, disabledReason: "Paused by the update…")), [.paused])
        XCTAssertEqual(AutomationRowPresentation.chips(item(id: 1, name: "a", parseError: "bad yaml")), [.cantRead])
        XCTAssertEqual(AutomationRowPresentation.chips(item(id: 1, name: "a", enabled: false)), [])
        XCTAssertEqual([AutomationRowChip.needsConfirmation, .paused, .cantRead, .draft].map(\.title),
                       ["Needs confirmation", "Paused", "Can't read", "Draft"])
    }

    func testOffLinePrefix() {
        let off = item(id: 1, name: "a", enabled: false)
        let on = item(id: 2, name: "b")
        XCTAssertTrue(AutomationRowPresentation.line(off, changes: nil, now: now).hasPrefix("Off · "))
        XCTAssertEqual(AutomationRowPresentation.line(off, changes: nil, now: now),
                       "Off · " + AutomationCardPresentation.rowDetailLine(off, changes: nil, now: now))
        XCTAssertFalse(AutomationRowPresentation.line(on, changes: nil, now: now).hasPrefix("Off"))
        XCTAssertFalse(AutomationRowPresentation.isOn(off))
        XCTAssertTrue(AutomationRowPresentation.isOn(on))
    }

    // MARK: - Draft rows

    private var pool: DatabasePool!
    private var path = ""

    override func setUp() async throws {
        try await super.setUp()
        (pool, path) = try TestDatabase.createPool()
    }

    override func tearDown() async throws {
        pool = nil
        TestDatabase.cleanup(path: path)
        try await super.tearDown()
    }

    private func insertDraftConversation(_ contextID: String) throws -> Int64 {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
                VALUES ('New automation', 'automation_draft', ?, 0, 0)
                """, arguments: [contextID])
            return db.lastInsertedRowID
        }
    }

    private func line(name: String) -> String {
        #"{"recipe_text":"---\nname: \#(name)\n---","result":{"ok":true,"errors":[],"#
            + #""manifest":{"name":"\#(name)","slug":"","trigger_kind":"manual","trigger":"manual","permissions":[],"#
            + #""outputs":[],"budget_tokens":40000,"budget_minutes":5},"dry_run":null},"at":"2026-10-21T09:00:00Z"}"#
    }

    private func writeCache(_ conversationID: Int64, _ text: String, modified: Date) throws {
        let url = AutomationDraftEntry.cacheURL(databasePath: path, conversationID: conversationID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func testDraftRowsFromCacheFiles() throws {
        let personal = try insertDraftConversation("d1")
        let workbench = try insertDraftConversation("d2-wb3")
        _ = try insertDraftConversation("d4")
        let broken = try insertDraftConversation("d5")
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
                VALUES ('Automation: x', 'automation', '7', 0, 0)
                """)
        }
        try writeCache(personal, line(name: "Mail digest") + "\n", modified: now.addingTimeInterval(-60))
        try writeCache(workbench, line(name: "Old") + "\n" + line(name: "Release notes") + "\n", modified: now)
        try writeCache(broken, line(name: "Fine") + "\n{not json\n", modified: now)

        let rows = try pool.read { db in
            try AutomationDraftRows.load(db, databasePath: path, liveWorkbenchIDs: [3])
        }
        XCTAssertEqual(rows.map(\.conversationID), [workbench, personal])
        XCTAssertEqual(rows.map(\.workbenchID), [3, nil])
        XCTAssertEqual(rows.map(\.name), ["Release notes", "Mail digest"])
        XCTAssertEqual(rows.map(\.contextID), ["d2-wb3", "d1"])
        XCTAssertEqual(rows.first?.updatedAt.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(rows.first?.id, workbench)
    }

    func testDraftOfAGoneWorkbenchIsNotListed() throws {
        let gone = try insertDraftConversation("d3-wb9")
        try writeCache(gone, line(name: "Gone") + "\n", modified: now)
        let rows = try pool.read { db in
            try AutomationDraftRows.load(db, databasePath: path, liveWorkbenchIDs: [3])
        }
        XCTAssertEqual(rows, [])
    }

    func testDraftWithoutAManifestNameIsANewAutomation() throws {
        let id = try insertDraftConversation("d6")
        try writeCache(id, #"{"recipe_text":"x","result":null,"error":"boom"}"# + "\n", modified: now)
        let rows = try pool.read { db in
            try AutomationDraftRows.load(db, databasePath: path, liveWorkbenchIDs: [])
        }
        XCTAssertEqual(rows.map(\.name), ["New automation"])
    }

    /// A draft row's line 2: the drafted recipe's summary, else its
    /// description's first sentence; none without a drafted recipe.
    func testDraftRowSummaryFromTheDraftedRecipe() throws {
        let own = try insertDraftConversation("d7")
        let derived = try insertDraftConversation("d8")
        let failed = try insertDraftConversation("d9")
        try writeCache(own, #"{"recipe_text":"---\nname: A\nsummary: Sorts the mail\n---\nLong text.","result":null}"#
            + "\n", modified: now)
        try writeCache(derived, #"{"recipe_text":"---\nname: B\n---\nPosts a digest. Then more.","result":null}"#
            + "\n", modified: now.addingTimeInterval(-1))
        try writeCache(failed, #"{"recipe_text":"","result":null,"error":"boom"}"# + "\n",
                       modified: now.addingTimeInterval(-2))
        let rows = try pool.read { db in
            try AutomationDraftRows.load(db, databasePath: path, liveWorkbenchIDs: [])
        }
        XCTAssertEqual(rows.map(\.summary), ["Sorts the mail", "Posts a digest.", nil])
    }

    func testWorkbenchIDFromContextID() {
        XCTAssertNil(AutomationDraftRows.workbenchID(fromContextID: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        XCTAssertEqual(AutomationDraftRows.workbenchID(fromContextID: "6F9619FF-8B86-D011-B42D-00C04FC964FF-wb12"), 12)
        XCTAssertNil(AutomationDraftRows.workbenchID(fromContextID: "d-wb"))
        XCTAssertNil(AutomationDraftRows.workbenchID(fromContextID: "d-wbx"))
    }

    func testBuiltinItemsListedInBuiltIn() {
        let brief = Automation(id: 9, slug: "morning-brief", name: "Morning brief", origin: .builtin,
                               builtinID: "morning-brief")
        let builtin = AutomationListItem(automation: brief, lastRun: nil, activeRun: nil, tokens7d: 0, badges: [],
                                         triggerText: "")
        let sections = AutomationListSections.make(
            items: [item(id: 1, name: "Mail digest"), builtin], drafts: [draft(5, name: "Draft")],
            workbenches: [], query: "")
        XCTAssertEqual(sections.map(\.title), [AutomationListSections.builtinTitle, AutomationListSections.personalTitle])
        XCTAssertEqual(AutomationListSections.builtinTitle, "Built in")
        XCTAssertEqual(sections[0].items.map(\.id), [9])
        XCTAssertEqual(sections[0].drafts, [])
        XCTAssertEqual(sections[1].items.map(\.id), [1], "never in Personal")
        XCTAssertEqual(AutomationListSections.make(items: [builtin], drafts: [], workbenches: [], query: "zzz"), [])
    }
}

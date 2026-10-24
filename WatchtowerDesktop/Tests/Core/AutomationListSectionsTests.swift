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

    /// A scheduled recipe, optionally with a newest run and a next run.
    private func scheduled(
        enabled: Bool = true,
        confirmed: Bool = true,
        disabledReason: String = "",
        lastRun: AutomationRun? = nil,
        nextRunAt: Date? = nil,
        tokens7d: Int64 = 0
    ) -> AutomationListItem {
        let automation = Automation(
            id: 1, slug: "docs", name: "Docs", triggerKind: "schedule", triggerSpecJSON: #"{"schedule":"0 7 * * *"}"#,
            approvalHash: "h2", confirmedHash: confirmed ? "h2" : "h1", enabled: enabled, nextRunAt: nextRunAt,
            disabledReason: disabledReason
        )
        return AutomationListItem(
            automation: automation, lastRun: lastRun, activeRun: nil, tokens7d: tokens7d,
            badges: AutomationListItem.badges(for: automation, grants: []), triggerText: "Daily 07:00"
        )
    }

    private func failedRun(_ error: String) -> AutomationRun {
        AutomationRun(id: 5, automationID: 1, status: .failed, error: error, finishedAt: now.addingTimeInterval(-3600))
    }

    /// Line 1 says "off" (or the dot does, behind a chip): line 3 never does.
    func testLineHasNoOffPrefix() {
        let off = item(id: 1, name: "a", enabled: false)
        XCTAssertEqual(AutomationRowPresentation.line(off, changes: nil, now: now),
                       AutomationCardPresentation.rowDetailLine(off, changes: nil, now: now))
        XCTAssertFalse(AutomationRowPresentation.line(off, changes: nil, now: now).hasPrefix("Off"))
        XCTAssertFalse(AutomationRowPresentation.isOn(off))
        XCTAssertTrue(AutomationRowPresentation.isOn(item(id: 2, name: "b")))
    }

    /// A failed last run leads line 3 with its error's first line, so a cut
    /// line still shows it, and the line is a warning.
    func testFailedLineLeadsWithTheError() {
        let failed = scheduled(lastRun: failedRun("fetch: example.com timed out\nstack"))
        XCTAssertEqual(AutomationRowPresentation.line(failed, changes: nil, now: now),
                       "fetch: example.com timed out · Daily 07:00")
        XCTAssertTrue(AutomationRowPresentation.isFailed(failed))
        XCTAssertEqual(AutomationRowPresentation.state(failed, now: now), .failed)
        XCTAssertFalse(AutomationRowPresentation.isFailed(scheduled()))
    }

    /// Behind a Needs confirmation or Paused chip, a failed run still shows
    /// its error first, as a warning.
    func testFailedRunBehindAChipStillWarns() {
        for item in [scheduled(confirmed: false, lastRun: failedRun("boom")),
                     scheduled(enabled: false, disabledReason: "stopped", lastRun: failedRun("boom"))] {
            guard case .chip = AutomationRowPresentation.state(item, now: now) else {
                return XCTFail("expected a chip on line 1")
            }
            XCTAssertTrue(AutomationRowPresentation.isFailed(item))
            XCTAssertEqual(AutomationRowPresentation.line(item, changes: nil, now: now), "boom · Daily 07:00")
        }
    }

    /// Line 1 shows the next run, so line 3 keeps the trigger (and the
    /// week's tokens) without saying it again.
    func testNextRunIsNotRepeated() {
        let next = now.addingTimeInterval(26 * 60)
        let idle = scheduled(nextRunAt: next)
        XCTAssertEqual(AutomationRowPresentation.state(idle, now: now), .next("in 26 min"))
        XCTAssertEqual(AutomationRowPresentation.line(idle, changes: nil, now: now), "Daily 07:00")
        let busy = scheduled(nextRunAt: next, tokens7d: 7300)
        XCTAssertEqual(AutomationRowPresentation.line(busy, changes: nil, now: now),
                       "Daily 07:00 · 7.3k tokens this week")
        // A last run on line 1 leaves the next run to line 3.
        let ran = scheduled(lastRun: AutomationRun(id: 6, automationID: 1, status: .succeeded,
                                                   finishedAt: now.addingTimeInterval(-3600)),
                            nextRunAt: next)
        XCTAssertTrue(AutomationRowPresentation.line(ran, changes: nil, now: now).contains("next in 26 min"))
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

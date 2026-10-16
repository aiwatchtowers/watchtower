import XCTest
@testable import WatchtowerCore

/// Quick run's rows (spec §12.7): who is listed, in which order, with which
/// state, reason and hint, and the palette's fuzzy ranking.
final class QuickRunCatalogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_152_000) // 2026-10-16T12:00:00Z

    private func item(
        _ id: Int64,
        _ name: String,
        workbench: Int64? = nil,
        kind: String = "manual",
        spec: String = #"{"manual":true}"#,
        approval: String = "h1",
        confirmed: String = "h1",
        parseError: String = "",
        enabled: Bool = true,
        removed: Bool = false,
        recipe: String = "",
        lastRun: AutomationRun? = nil,
        activeRun: AutomationRun? = nil
    ) -> AutomationListItem {
        let automation = Automation(
            id: id, slug: name.lowercased(), scope: workbench == nil ? .personal : .workbench, projectID: workbench,
            name: name, triggerKind: kind, triggerSpecJSON: spec, recipeText: recipe, approvalHash: approval,
            confirmedHash: confirmed, parseError: parseError, enabled: enabled, removedAt: removed ? now : nil
        )
        return AutomationListItem(automation: automation, lastRun: lastRun, activeRun: activeRun, tokens7d: 0,
                                  badges: [], triggerText: "")
    }

    private func row(_ items: [AutomationListItem], _ id: Int64) throws -> QuickRunRow {
        try XCTUnwrap(QuickRunCatalog.rows(items, workbenchNames: [:]).first { $0.id == id })
    }

    func testRowsGroupedByWorkbenchThenPersonal() {
        let rows = QuickRunCatalog.rows([
            item(1, "Inbox sweep"),
            item(2, "Release", workbench: 20),
            item(3, "Backup", workbench: 10),
            item(4, "Archive")
        ], workbenchNames: [10: "zeta", 20: "acme"])
        XCTAssertEqual(rows.map(\.name), ["Release", "Backup", "Archive", "Inbox sweep"])
        XCTAssertEqual(rows.map(\.group), [
            .workbench(id: 20, name: "acme"), .workbench(id: 10, name: "zeta"), .personal, .personal
        ])
    }

    func testManualAndButtonBeforeScheduled() throws {
        let items = [
            item(1, "Alpha digest", kind: "schedule", spec: #"{"schedule":"0 9 * * *"}"#),
            item(2, "Zed release", kind: "button", spec: #"{"button":{"label":"Ship","confirm":false}}"#),
            item(3, "Middle", kind: "manual")
        ]
        let rows = QuickRunCatalog.rows(items, workbenchNames: [:])
        XCTAssertEqual(rows.map(\.name), ["Middle", "Zed release", "Alpha digest"])
        XCTAssertEqual(rows.last?.kind, .scheduledOrEvent)
        XCTAssertEqual(rows.last?.hint, "(run now)")
        XCTAssertEqual(try row(items, 2).kind, .button)
    }

    func testRemovedRowsExcluded() {
        let rows = QuickRunCatalog.rows([item(1, "Kept"), item(2, "Gone", removed: true)], workbenchNames: [:])
        XCTAssertEqual(rows.map(\.id), [1])
    }

    func testStatesAndReasons() throws {
        let active = AutomationRun(id: 50, automationID: 2, status: .running)
        let items = [
            item(1, "Runnable"),
            item(2, "Running", activeRun: active),
            item(3, "Unconfirmed", approval: "h2", confirmed: "h1"),
            item(4, "Off", enabled: false),
            item(5, "Broken", parseError: "line 3: bad"),
            item(6, "Unconfirmed and off", approval: "h2", confirmed: "", enabled: false)
        ]
        let want: [(Int64, QuickRunRow.State, String?)] = [
            (1, .runnable, nil),
            (2, .running(runID: 50), nil),
            (3, .needsConfirmation, "needs your confirmation first"),
            (4, .disabled, "disabled"),
            (5, .parseError, "can't be read"),
            (6, .needsConfirmation, "needs your confirmation first")
        ]
        for (id, state, reason) in want {
            let row = try row(items, id)
            XCTAssertEqual(row.state, state, row.name)
            XCTAssertEqual(row.reason, reason, row.name)
        }
        // `.runnable` exactly when `isRunnable` (the card's Run now and the CLI's rule).
        for listed in items where listed.activeRun == nil {
            XCTAssertEqual(try row(items, listed.id).state == .runnable, listed.automation.isRunnable,
                           listed.automation.name)
        }
    }

    func testHints() throws {
        let items = [
            item(1, "Release", kind: "button", spec: #"{"button":{"label":"Release","confirm":true}}"#),
            item(2, "Notes", kind: "manual"),
            item(3, "Ship", kind: "button", spec: #"{"button":{"label":"Ship"}}"#)
        ]
        let release = try row(items, 1)
        XCTAssertTrue(release.asksFirst)
        XCTAssertEqual(release.hint, "asks before it runs")
        XCTAssertEqual(try row(items, 2).hint, "only when you run it")
        XCTAssertFalse(try row(items, 3).asksFirst)
        XCTAssertEqual(try row(items, 3).hint, "only when you run it")
    }

    func testFuzzyRankingOrder() {
        let rows = QuickRunCatalog.rows([
            item(1, "Unrelated"),
            item(2, "Draft release notes"),
            item(3, "Release"),
            item(4, "Inbox sweep")
        ], workbenchNames: [:])
        XCTAssertEqual(QuickRunCatalog.ranked(rows, query: "rel").map(\.name),
                       ["Release", "Draft release notes", "Unrelated"])
        XCTAssertEqual(QuickRunCatalog.ranked(rows, query: "RÉL").first?.name, "Release",
                       "case- and diacritic-insensitive")
        XCTAssertEqual(QuickRunCatalog.ranked(rows, query: "rls").map(\.name), ["Draft release notes", "Release"],
                       "matches by subsequence; equal scores keep the group order")
        XCTAssertEqual(QuickRunCatalog.score("Release", query: "rls"), QuickRunCatalog.subsequence)
        XCTAssertEqual(QuickRunCatalog.score("Release", query: "release"), QuickRunCatalog.exact)
        XCTAssertEqual(QuickRunCatalog.ranked(rows, query: "xyz"), [], "no match is dropped")
    }

    func testRankingCapsAtFifty() {
        let rows = QuickRunCatalog.rows((1...60).map { item(Int64($0), "Job \($0)") }, workbenchNames: [:])
        XCTAssertEqual(QuickRunCatalog.ranked(rows, query: "job").count, QuickRunCatalog.limit)
    }

    func testEmptyQueryKeepsGroupOrder() {
        let rows = QuickRunCatalog.rows([
            item(1, "Zulu"),
            item(2, "Alpha", workbench: 7),
            item(3, "Mike")
        ], workbenchNames: [7: "acme"])
        XCTAssertEqual(QuickRunCatalog.ranked(rows, query: ""), rows)
        XCTAssertEqual(QuickRunCatalog.ranked(rows, query: "   "), rows)
    }

    func testLastRunText() throws {
        let finished = now.addingTimeInterval(-2 * 86_400)
        let last = AutomationRun(id: 9, automationID: 1, status: .succeeded, finishedAt: finished)
        let items = [item(1, "Release", lastRun: last), item(2, "Fresh")]
        XCTAssertEqual(try row(items, 1).lastRunText(now: now), "last run 2 days ago, succeeded")
        XCTAssertNil(try row(items, 2).lastRunText(now: now))
        let failed = AutomationRun(id: 10, automationID: 1, status: .budgetExceeded, finishedAt: now.addingTimeInterval(-10))
        XCTAssertEqual(try row([item(1, "Release", lastRun: failed)], 1).lastRunText(now: now),
                       "last run just now, budget exceeded")
    }

    func testDescriptionLeadIsTheFirstParagraph() {
        let recipe = """
            ---
            name: Release
            trigger:
              button: { label: Release, confirm: true }
            ---
            # Release

            Runs make release in the workbench,
            then starts a check session.

            Second paragraph.

            ```js
            log("hi")
            ```
            """
        XCTAssertEqual(QuickRunCatalog.descriptionLead(recipe),
                       "Runs make release in the workbench, then starts a check session.")
        XCTAssertEqual(QuickRunCatalog.descriptionLead("---\nname: x\n---\n```js\nlog(1)\n```\n"), "")
    }
}

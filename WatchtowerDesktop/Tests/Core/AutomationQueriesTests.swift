import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

final class AutomationQueriesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_152_000) // 2026-10-16T12:00:00Z

    private func stamp(_ offset: TimeInterval) -> String {
        AutomationDates.format(now.addingTimeInterval(offset))
    }

    func testListExcludesRemovedAndOrdersByName() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertAutomation(db, slug: "zeta", name: "Zeta report")
            try TestDatabase.insertAutomation(db, slug: "gone", name: "Gone", removedAt: "2026-10-10T00:00:00Z")
            try TestDatabase.insertAutomation(db, slug: "alpha", name: "alpha mail")
            try TestDatabase.insertAutomation(db, slug: "mid", name: "Mid")
        }
        let items = try queue.read { db in try AutomationQueries.fetchList(db, now: now) }
        XCTAssertEqual(items.map(\.automation.name), ["alpha mail", "Mid", "Zeta report"])
    }

    func testListCarriesLastAndActiveRunsAndTriggerText() throws {
        let queue = try TestDatabase.create()
        let (id, finished, active) = try queue.write { db -> (Int64, Int64, Int64) in
            let id = try TestDatabase.insertAutomation(db, triggerKind: "schedule",
                                                       triggerSpec: #"{"schedule":"0 9 * * 1-5"}"#)
            try TestDatabase.insertAutomationRun(db, automationID: id, status: "failed")
            let finished = try TestDatabase.insertAutomationRun(db, automationID: id, status: "succeeded")
            let active = try TestDatabase.insertAutomationRun(db, automationID: id, status: "running")
            return (id, finished, active)
        }
        let item = try XCTUnwrap(try queue.read { db in try AutomationQueries.fetchList(db, now: now) }.first)
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.lastRun?.id, finished)
        XCTAssertEqual(item.activeRun?.id, active)
        XCTAssertEqual(item.triggerText, "Weekdays 09:00")
    }

    func testBadges() throws {
        struct Case {
            let name: String
            let approval: String
            let confirmed: String
            let parseError: String
            let enabled: Bool
            let grantHash: String?
            let want: [AutomationRowBadge]
        }
        let cases = [
            Case(name: "unconfirmed", approval: "h2", confirmed: "", parseError: "", enabled: true, grantHash: nil,
                 want: [.needsConfirmation]),
            Case(name: "auto paused", approval: "h2", confirmed: "h2", parseError: "", enabled: true, grantHash: "h1",
                 want: [.autoPaused]),
            Case(name: "active grant", approval: "h2", confirmed: "h2", parseError: "", enabled: true, grantHash: "h2",
                 want: []),
            Case(name: "disabled", approval: "h1", confirmed: "h1", parseError: "", enabled: false, grantHash: nil,
                 want: [.disabled]),
            Case(name: "parse error", approval: "", confirmed: "h1", parseError: "line 2: bad", enabled: false,
                 grantHash: "h1", want: [.parseError])
        ]
        for c in cases {
            let queue = try TestDatabase.create()
            try queue.write { db in
                let id = try TestDatabase.insertAutomation(db, approvalHash: c.approval, confirmedHash: c.confirmed,
                                                           parseError: c.parseError, enabled: c.enabled)
                if let grantHash = c.grantHash {
                    try TestDatabase.insertAutomationGrant(db, automationID: id, tool: "create_jira_issue",
                                                           grantHash: grantHash)
                }
            }
            let item = try XCTUnwrap(try queue.read { db in try AutomationQueries.fetchList(db, now: now) }.first)
            XCTAssertEqual(item.badges, c.want, c.name)
        }
    }

    func testTokens7dRollingWindowIncludesDryRuns() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let id = try TestDatabase.insertAutomation(db)
            let day: TimeInterval = 24 * 60 * 60
            try TestDatabase.insertAutomationRun(db, automationID: id, inputTokens: 100, outputTokens: 20,
                                                 startedAt: stamp(-(6 * day + 23 * 3600)))
            try TestDatabase.insertAutomationRun(db, automationID: id, trigger: "dry_run", inputTokens: 5,
                                                 outputTokens: 5, startedAt: stamp(-3600))
            try TestDatabase.insertAutomationRun(db, automationID: id, inputTokens: 1000, outputTokens: 1000,
                                                 startedAt: stamp(-(7 * day + 3600)))
            try TestDatabase.insertAutomationRun(db, automationID: id, status: "queued", inputTokens: 0,
                                                 startedAt: nil)
        }
        let item = try XCTUnwrap(try queue.read { db in try AutomationQueries.fetchList(db, now: now) }.first)
        XCTAssertEqual(item.tokens7d, 130)
    }

    func testAttentionCountCountsConfirmationAndOwnerWaits() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertAutomation(db, slug: "new", approvalHash: "h1", confirmedHash: "")
            try TestDatabase.insertAutomation(db, slug: "broken", approvalHash: "", confirmedHash: "x",
                                              parseError: "bad")
            try TestDatabase.insertAutomation(db, slug: "gone", approvalHash: "h1", confirmedHash: "",
                                              removedAt: "2026-10-10T00:00:00Z")
            let ok = try TestDatabase.insertAutomation(db, slug: "ok")
            for reason in ["approval", "ask", "app", "session"] {
                try TestDatabase.insertAutomationRun(db, automationID: ok, status: "waiting", waitingReason: reason)
            }
            try TestDatabase.insertAutomationRun(db, automationID: ok, status: "running")
        }
        XCTAssertEqual(try queue.read { db in try AutomationQueries.attentionCount(db) }, 3)
    }

    func testInboxOutputsOnlyUnreadInboxKind() throws {
        let queue = try TestDatabase.create()
        let (id, run, older, newer) = try queue.write { db -> (Int64, Int64, Int64, Int64) in
            let id = try TestDatabase.insertAutomation(db, name: "Mail summary")
            let run = try TestDatabase.insertAutomationRun(db, automationID: id)
            let older = try TestDatabase.insertAutomationOutput(db, automationID: id, runID: run, title: "older",
                                                                createdAt: "2026-10-01T09:00:00Z")
            let newer = try TestDatabase.insertAutomationOutput(db, automationID: id, runID: run, title: "newer",
                                                                priority: "high", createdAt: "2026-10-02T09:00:00Z")
            try TestDatabase.insertAutomationOutput(db, automationID: id, runID: run, kind: "report")
            try TestDatabase.insertAutomationOutput(db, automationID: id, runID: run, kind: "briefing")
            try TestDatabase.insertAutomationOutput(db, automationID: id, runID: run, readAt: "2026-10-03T00:00:00Z")
            try TestDatabase.insertAutomationOutput(db, automationID: id, runID: run,
                                                    dismissedAt: "2026-10-03T00:00:00Z")
            return (id, run, older, newer)
        }
        let cards = try queue.read { db in try AutomationQueries.fetchInboxOutputs(db) }
        XCTAssertEqual(cards.map(\.id), [newer, older])
        XCTAssertEqual(cards[0], AutomationOutputCard(
            id: newer, automationID: id, automationName: "Mail summary", runID: run, title: "newer",
            body: "Two threads need you.", priority: "high", createdAt: try XCTUnwrap(AutomationDates.parse("2026-10-02T09:00:00Z"))))
        XCTAssertEqual(try queue.read { db in try AutomationQueries.inboxOutputCount(db) }, 2)
    }

    func testOutputWritesTouchOnlyReadAndDismissed() throws {
        let queue = try TestDatabase.create()
        let (read, dismissed) = try queue.write { db -> (Int64, Int64) in
            let id = try TestDatabase.insertAutomation(db)
            let run = try TestDatabase.insertAutomationRun(db, automationID: id)
            return (try TestDatabase.insertAutomationOutput(db, automationID: id, runID: run, title: "a"),
                    try TestDatabase.insertAutomationOutput(db, automationID: id, runID: run, title: "b"))
        }
        let before = try queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM automation_outputs ORDER BY id") }
        try queue.write { db in
            try AutomationQueries.markOutputRead(db, id: read, now: now)
            try AutomationQueries.dismissOutput(db, id: dismissed, now: now)
            // Guarded: a second mark on either row changes nothing.
            try AutomationQueries.dismissOutput(db, id: read, now: now.addingTimeInterval(60))
            try AutomationQueries.markOutputRead(db, id: dismissed, now: now.addingTimeInterval(60))
        }
        let after = try queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM automation_outputs ORDER BY id") }
        XCTAssertEqual(after.count, before.count)
        for (old, new) in zip(before, after) {
            for column in old.columnNames where column != "read_at" && column != "dismissed_at" {
                XCTAssertEqual(old[column] as DatabaseValue, new[column] as DatabaseValue, column)
            }
        }
        XCTAssertEqual(after[0]["read_at"] as String?, "2026-10-16T12:00:00Z")
        XCTAssertNil(after[0]["dismissed_at"] as String?)
        XCTAssertNil(after[1]["read_at"] as String?)
        XCTAssertEqual(after[1]["dismissed_at"] as String?, "2026-10-16T12:00:00Z")
    }

    func testRunLabels() throws {
        let queue = try TestDatabase.create()
        let (run, unnamedRun) = try queue.write { db -> (Int64, Int64) in
            let id = try TestDatabase.insertAutomation(db, name: "Mail summary")
            let unnamed = try TestDatabase.insertAutomation(db, slug: "broken", name: "", parseError: "bad")
            return (try TestDatabase.insertAutomationRun(db, automationID: id),
                    try TestDatabase.insertAutomationRun(db, automationID: unnamed))
        }
        let labels = try queue.read { db in
            try AutomationQueries.runLabels(db, runIDs: [run, unnamedRun, 999])
        }
        XCTAssertEqual(labels, [run: "⚙ Mail summary · run #\(run)", unnamedRun: "⚙ broken · run #\(unnamedRun)"])
        XCTAssertEqual(try queue.read { db in try AutomationQueries.runLabels(db, runIDs: []) }, [:])
    }

    func testDatesDecodeAsUTC() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db -> Int64 in
            let id = try TestDatabase.insertAutomation(db, nextRunAt: "2026-10-17T09:00:00Z")
            try TestDatabase.insertAutomationRun(db, automationID: id, startedAt: "2026-10-16T23:30:00Z",
                                                 finishedAt: "2026-10-16T23:31:00Z")
            return id
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let item = try XCTUnwrap(try queue.read { db in try AutomationQueries.fetchList(db, now: now) }.first)
        let next = try XCTUnwrap(item.automation.nextRunAt)
        XCTAssertEqual(utc.dateComponents([.year, .month, .day, .hour, .minute], from: next),
                       DateComponents(year: 2026, month: 10, day: 17, hour: 9, minute: 0))
        let run = try XCTUnwrap(try queue.read { db in try AutomationQueries.fetchRuns(db, automationID: id, limit: 5) }.first)
        XCTAssertEqual(run.startedAt.map { utc.component(.hour, from: $0) }, 23)
        XCTAssertEqual(run.finishedAt?.timeIntervalSince1970, AutomationDates.parse("2026-10-16T23:31:00Z")?.timeIntervalSince1970)
        XCTAssertEqual(AutomationDates.format(next), "2026-10-17T09:00:00Z")
    }

    func testCardReadsStepsGrantsReports() throws {
        let queue = try TestDatabase.create()
        let (id, run) = try queue.write { db -> (Int64, Int64) in
            let id = try TestDatabase.insertAutomation(db, permissionsJSON: #"["jira:read@OPS"]"#,
                                                       outputsJSON: #"["report"]"#)
            let run = try TestDatabase.insertAutomationRun(db, automationID: id)
            try TestDatabase.insertAutomationStep(db, runID: run, seq: 2, kind: "output", name: "report")
            try TestDatabase.insertAutomationStep(db, runID: run, seq: 1)
            try TestDatabase.insertAutomationOutput(db, automationID: id, runID: run, kind: "report", title: "r")
            try TestDatabase.insertAutomationOutput(db, automationID: id, runID: run, kind: "inbox")
            try TestDatabase.insertAutomationGrant(db, automationID: id, tool: "create_jira_issue", grantHash: "h1")
            return (id, run)
        }
        try queue.read { db in
            let automation = try XCTUnwrap(try AutomationQueries.fetchList(db, now: now).first?.automation)
            XCTAssertEqual(automation.permissions, ["jira:read@OPS"])
            XCTAssertEqual(automation.outputs, ["report"])
            XCTAssertTrue(automation.isRunnable)
            XCTAssertEqual(try AutomationQueries.fetchSteps(db, runID: run).map(\.seq), [1, 2])
            XCTAssertEqual(try AutomationQueries.fetchReports(db, automationID: id, limit: 5).map(\.title), ["r"])
            let grants = try AutomationQueries.fetchGrants(db, automationID: id)
            XCTAssertEqual(grants.map(\.tool), ["create_jira_issue"])
            XCTAssertTrue(grants[0].isActive(approvalHash: "h1"))
            XCTAssertFalse(grants[0].isActive(approvalHash: "h2"))
        }
    }

    func testIsRunnableMirrorsGo() {
        func make(
            approval: String = "h",
            confirmed: String = "h",
            parseError: String = "",
            enabled: Bool = true,
            removed: Date? = nil
        ) -> Automation {
            Automation(id: 1, slug: "s", approvalHash: approval, confirmedHash: confirmed, parseError: parseError,
                       enabled: enabled, removedAt: removed)
        }
        XCTAssertTrue(make().isRunnable)
        XCTAssertFalse(make(enabled: false).isRunnable)
        XCTAssertFalse(make(parseError: "x").isRunnable)
        XCTAssertFalse(make(removed: now).isRunnable)
        XCTAssertFalse(make(confirmed: "").isRunnable)
        XCTAssertFalse(make(approval: "", confirmed: "").isRunnable, "an empty confirmed hash is never confirmed")
        XCTAssertFalse(make(confirmed: "old").isRunnable)
        XCTAssertTrue(make(confirmed: "old").needsConfirmation)
        XCTAssertFalse(make(confirmed: "old", removed: now).needsConfirmation)
    }

    func testRunStatusBadges() {
        let want: [AutomationRunStatus: StatusBadge] = [
            .succeeded: .green, .running: .blue, .waiting: .blue, .queued: .blue, .failed: .red, .timedOut: .red,
            .expired: .red, .budgetExceeded: .orange, .cancelled: .grey
        ]
        for (status, badge) in want { XCTAssertEqual(status.badge, badge, status.rawValue) }
        XCTAssertEqual([AutomationRunStatus.queued, .running, .waiting].filter(\.isActive).count, 3)
        XCTAssertFalse(AutomationRunStatus.succeeded.isActive)
    }

    /// The quick-run finish watch reads its runs by id: only the asked ids,
    /// a missing id absent, and no query at all for none.
    func testFetchRunsByIDs() throws {
        let queue = try TestDatabase.create()
        let (first, second, other) = try queue.write { db -> (Int64, Int64, Int64) in
            let id = try TestDatabase.insertAutomation(db)
            let first = try TestDatabase.insertAutomationRun(db, automationID: id, status: "succeeded")
            let second = try TestDatabase.insertAutomationRun(db, automationID: id, status: "running")
            let other = try TestDatabase.insertAutomationRun(db, automationID: id, status: "failed")
            return (first, second, other)
        }
        let runs = try queue.read { db in try AutomationQueries.fetchRuns(db, ids: [second, first, 9999]) }
        XCTAssertEqual(Set(runs.map(\.id)), [first, second])
        XCTAssertFalse(runs.contains { $0.id == other })
        XCTAssertEqual(runs.first { $0.id == second }?.status, .running)

        var statements = 0
        let none = try queue.read { db -> [AutomationRun] in
            db.trace { _ in statements += 1 }
            defer { db.trace(options: [], nil) }
            return try AutomationQueries.fetchRuns(db, ids: [])
        }
        XCTAssertEqual(none, [])
        XCTAssertEqual(statements, 0, "no ids, no query")
    }

}

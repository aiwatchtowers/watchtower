import XCTest
@testable import WatchtowerCore

final class AutomationCardPresentationTests: XCTestCase {
    private typealias ACP = AutomationCardPresentation

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func automation(
        cron: String = "0 9 * * 1-5",
        kind: String = "schedule",
        spec: String? = nil,
        enabled: Bool = true,
        confirmed: Bool = true,
        parseError: String = "",
        nextRunAt: Date? = nil,
        budgetTokens: Int = 40000,
        budgetMinutes: Int = 5,
        concurrency: Int = 1,
        missed: String = "run_once"
    ) -> Automation {
        Automation(
            id: 7, slug: "digest", name: "Morning mail digest", triggerKind: kind,
            triggerSpecJSON: spec ?? #"{"schedule":"\#(cron)"}"#, missedPolicy: missed,
            concurrency: concurrency, budgetTokens: budgetTokens, budgetMinutes: budgetMinutes,
            approvalHash: "h2", confirmedHash: confirmed ? "h2" : "h1", parseError: parseError,
            enabled: enabled, nextRunAt: nextRunAt
        )
    }

    private func item(
        _ automation: Automation, lastRun: AutomationRun? = nil, activeRun: AutomationRun? = nil, tokens7d: Int64 = 0
    ) -> AutomationListItem {
        AutomationListItem(
            automation: automation, lastRun: lastRun, activeRun: activeRun, tokens7d: tokens7d,
            badges: AutomationListItem.badges(for: automation, grants: []),
            triggerText: AutomationTriggerText.describe(kind: automation.triggerKind, specJSON: automation.triggerSpecJSON)
        )
    }

    private func run(
        _ status: AutomationRunStatus,
        error: String = "",
        errorKind: String = "",
        trigger: String = "schedule",
        waitingReason: String = "",
        startedAt: Date? = nil
    ) -> AutomationRun {
        AutomationRun(id: 3, automationID: 7, trigger: trigger, status: status, waitingReason: waitingReason,
                      error: error, errorKind: errorKind, startedAt: startedAt)
    }

    // MARK: - Rows

    func testRowDetailLine() {
        let healthy = item(automation(nextRunAt: now.addingTimeInterval(14 * 3600)),
                           lastRun: run(.succeeded), tokens7d: 3200)
        XCTAssertEqual(ACP.rowDetailLine(healthy, changes: nil, now: now),
                       "Weekdays 09:00 · next in 14 h · 3.2k tokens this week")

        let failed = item(automation(cron: "30 8 * * 1", nextRunAt: now.addingTimeInterval(3600)),
                          lastRun: run(.failed, error: "Calendar not connected"))
        XCTAssertEqual(ACP.rowDetailLine(failed, changes: nil, now: now), "Mondays 08:30 · last run: Calendar not connected")

        let running = item(automation(cron: "0 17 * * 5"),
                           activeRun: run(.running, startedAt: now.addingTimeInterval(-40)))
        XCTAssertEqual(ACP.rowDetailLine(running, changes: nil, now: now), "Fridays 17:00 · started 40 s ago")

        let unconfirmed = item(automation(cron: "0 16 * * 5", confirmed: false))
        XCTAssertEqual(ACP.rowDetailLine(unconfirmed, changes: [AutomationChange(field: "trigger", old: "a", new: "b")],
                                         now: now),
                       "Fridays 16:00 · schedule changed, waiting for you")
        // Ruling A: without a loaded detail, or when the schedule is not among the changes.
        XCTAssertEqual(ACP.rowDetailLine(unconfirmed, changes: nil, now: now),
                       "Fridays 16:00 · waiting for your confirmation")
        XCTAssertEqual(ACP.rowDetailLine(unconfirmed, changes: [AutomationChange(field: "script", old: "", new: "")],
                                         now: now),
                       "Fridays 16:00 · waiting for your confirmation")

        let event = item(automation(kind: "event",
                                    spec: ##"{"event":{"type":"slack.new_messages","where":{"channel":"#eng"}}}"##,
                                    enabled: false))
        XCTAssertEqual(ACP.rowDetailLine(event, changes: nil, now: now), "On new Slack messages (#eng)")

        let waiting = item(automation(), activeRun: run(.waiting, waitingReason: "approval", startedAt: now))
        XCTAssertEqual(ACP.rowDetailLine(waiting, changes: nil, now: now), "Weekdays 09:00 · waiting for your approval")

        let broken = item(automation(kind: "", spec: "{}", parseError: "line 3: unknown key \"trigers\"\nmore"))
        XCTAssertEqual(ACP.rowDetailLine(broken, changes: nil, now: now), "can't be read: line 3: unknown key \"trigers\"")

        let manualNoRuns = item(automation(kind: "manual", spec: #"{"manual":true}"#))
        XCTAssertEqual(ACP.rowDetailLine(manualNoRuns, changes: nil, now: now), "Manual")
    }

    /// Board #583: an event recipe's row shows its real state (events shipped in P4), not "coming later".
    func testEventRowDetailLineShowsState() {
        let gmail = #"{"event":{"type":"gmail.new_messages"}}"#
        let fresh = item(automation(kind: "event", spec: gmail))
        XCTAssertEqual(ACP.rowDetailLine(fresh, changes: nil, now: now), "On new Gmail · no runs yet")

        let fired = item(automation(kind: "event", spec: gmail),
                         lastRun: AutomationRun(id: 3, automationID: 7, trigger: "event", status: .succeeded,
                                                startedAt: now.addingTimeInterval(-7300),
                                                finishedAt: now.addingTimeInterval(-7200)),
                         tokens7d: 3200)
        XCTAssertEqual(ACP.rowDetailLine(fired, changes: nil, now: now),
                       "On new Gmail · last run 2 h ago · 3.2k tokens this week")

        let running = item(automation(kind: "event", spec: gmail),
                           activeRun: run(.running, trigger: "event", startedAt: now.addingTimeInterval(-40)))
        XCTAssertEqual(ACP.rowDetailLine(running, changes: nil, now: now), "On new Gmail · started 40 s ago")

        let failed = item(automation(kind: "event", spec: gmail),
                          lastRun: run(.failed, error: "Gmail not connected", trigger: "event"))
        XCTAssertEqual(ACP.rowDetailLine(failed, changes: nil, now: now), "On new Gmail · last run: Gmail not connected")

        let overBudget = item(automation(kind: "event", spec: gmail), lastRun: run(.budgetExceeded, trigger: "event"))
        XCTAssertEqual(ACP.rowDetailLine(overBudget, changes: nil, now: now), "On new Gmail · last run: budget exceeded")

        let unconfirmed = item(automation(kind: "event", spec: gmail, confirmed: false))
        XCTAssertEqual(ACP.rowDetailLine(unconfirmed, changes: nil, now: now),
                       "On new Gmail · waiting for your confirmation")
    }

    func testStatusPillAndBadges() {
        let healthy = item(automation(), lastRun: run(.succeeded))
        XCTAssertEqual(ACP.statusPill(healthy), ACP.Pill(text: "Succeeded", badge: .green))
        let running = item(automation(), lastRun: run(.failed), activeRun: run(.running))
        XCTAssertEqual(ACP.statusPill(running), ACP.Pill(text: "Running", badge: .blue))
        XCTAssertNil(ACP.statusPill(item(automation())))
        XCTAssertEqual(ACP.statusText(.budgetExceeded), "Budget exceeded")
        XCTAssertEqual(ACP.badgeText(.needsConfirmation), "Needs your confirmation")
        XCTAssertEqual(ACP.badgeText(.autoPaused), "Auto paused")
        XCTAssertEqual(ACP.badgeText(.disabled), "Disabled")
        XCTAssertEqual(ACP.badgeText(.parseError), "Parse error")
    }

    // MARK: - Card

    func testSubtitle() {
        XCTAssertEqual(ACP.subtitle(automation(), workbenchName: nil), "Every weekday at 09:00 · personal · enabled")
        let workbench = Automation(id: 1, slug: "s", scope: .workbench, projectID: 4, triggerKind: "manual",
                                   triggerSpecJSON: #"{"manual":true}"#)
        XCTAssertEqual(ACP.subtitle(workbench, workbenchName: "acme-api"),
                       "Only when you run it · acme-api · disabled")
        XCTAssertEqual(ACP.subtitle(workbench, workbenchName: nil), "Only when you run it · workbench · disabled")
        XCTAssertEqual(ACP.subtitle(automation(cron: "30 8 * * 1"), workbenchName: nil),
                       "Every Monday at 08:30 · personal · enabled")
        XCTAssertEqual(ACP.subtitle(automation(cron: "0 9 * * *"), workbenchName: nil),
                       "Every day at 09:00 · personal · enabled")
    }

    func testLimitsLines() {
        XCTAssertEqual(ACP.limitsLines(automation()),
                       ["40,000 tokens · 5 minutes", "One run at a time", "Missed while asleep: run once"])
        XCTAssertEqual(ACP.limitsLines(automation(budgetMinutes: 1, concurrency: 3, missed: "skip")),
                       ["40,000 tokens · 1 minute", "Up to 3 runs at a time", "Missed while asleep: skip"])
        // The missed policy applies to a schedule only.
        XCTAssertEqual(ACP.limitsLines(automation(kind: "manual", spec: #"{"manual":true}"#)),
                       ["40,000 tokens · 5 minutes", "One run at a time"])
    }

    func testPermissionHumanLines() {
        XCTAssertEqual(ACP.permissionLine("gmail:read@work"), "Read mail in work (Gmail)")
        XCTAssertEqual(ACP.permissionLine("llm:light"), "Use the light model")
        XCTAssertEqual(ACP.permissionLine("llm:strong"), "Use the strong model")
        XCTAssertEqual(ACP.permissionLine("jira:read@*"), "Read issues in all projects (Jira)")
        XCTAssertEqual(ACP.permissionLine("linear:write@ENG"), "Change issues in ENG (Linear)")
        XCTAssertEqual(ACP.permissionLine("linear:read@*"), "Read issues in all teams (Linear)")
        XCTAssertEqual(ACP.permissionLine("slack:write@acme"), "Post messages in acme (Slack)")
        XCTAssertEqual(ACP.permissionLine("targets:read"), "Read your targets")
        XCTAssertEqual(ACP.permissionLine("tool:create_target"), "Use the tool create_target")
        XCTAssertEqual(ACP.permissionLine("mcp:github/list_*"), "Use list_* from github (Quick Connection)")
        XCTAssertEqual(ACP.permissionLine(#"shell:"make release""#), "Run the command make release")
        XCTAssertEqual(ACP.permissionLine("session:start@codex"), "Start Codex sessions")
        XCTAssertEqual(ACP.permissionLine("weird"), "weird")
        XCTAssertEqual(ACP.outputLine("inbox"), "Put cards in your Inbox")
        XCTAssertEqual(ACP.outputLine("report"), "Add reports to this automation")

        let lines = ACP.permissionLines(permissions: ["gmail:read@work", "llm:light"], outputs: ["inbox"],
                                        widening: ["gmail:read@work"])
        XCTAssertEqual(lines, [
            ACP.PermissionLine(text: "Read mail in work (Gmail)", isNew: true),
            ACP.PermissionLine(text: "Use the light model", isNew: false),
            ACP.PermissionLine(text: "Put cards in your Inbox", isNew: false)
        ])
    }

    func testWaitingReasonCaptions() {
        XCTAssertEqual(ACP.waitingCaption("approval"), "Waiting for your approval")
        XCTAssertEqual(ACP.waitingCaption("ask"), "Waiting for your answer")
        XCTAssertEqual(ACP.waitingCaption("app"), "Waiting for the app")
        XCTAssertEqual(ACP.waitingCaption("session"), "Waiting for a session")
        XCTAssertEqual(ACP.waitingCaption(""), "Waiting")
    }

    func testTokensShowEstimateMark() {
        XCTAssertEqual(ACP.tokensText(1180, estimated: false), "1,180 tokens")
        XCTAssertEqual(ACP.tokensText(1180, estimated: true), "≈1,180 tokens")
        XCTAssertEqual(ACP.compactTokens(3200), "3.2k")
        XCTAssertEqual(ACP.compactTokens(3000), "3k")
        XCTAssertEqual(ACP.compactTokens(950), "950")
        XCTAssertEqual(ACP.compactTokens(1_250_000), "1.3M")
    }

    func testReportedCostOnlyWhenPresent() {
        XCTAssertNil(ACP.reportedCostText(nil))
        XCTAssertEqual(ACP.reportedCostText(0.4211), "$0.42 reported")
        XCTAssertEqual(ACP.reportedCostText(0), "$0.00 reported")
    }

    func testButtonsForStates() {
        let ready = ACP.buttons(for: automation())
        XCTAssertEqual(ready.runNow, ACP.ButtonState(enabled: true, help: nil))
        XCTAssertEqual(ready.dryRun, ACP.ButtonState(enabled: true, help: nil))
        XCTAssertEqual(ready.toggleLabel, "Disable")

        let unconfirmed = ACP.buttons(for: automation(confirmed: false))
        XCTAssertEqual(unconfirmed.runNow, ACP.ButtonState(enabled: false, help: "Needs your confirmation"))
        // Ask #271: the owner may dry-run an unconfirmed recipe.
        XCTAssertTrue(unconfirmed.dryRun.enabled)

        let broken = ACP.buttons(for: automation(parseError: "bad"))
        XCTAssertFalse(broken.runNow.enabled)
        XCTAssertFalse(broken.dryRun.enabled)
        XCTAssertEqual(broken.runNow.help, "The recipe can't be read")

        let disabled = ACP.buttons(for: automation(enabled: false))
        XCTAssertEqual(disabled.runNow, ACP.ButtonState(enabled: false, help: "Disabled — enable it from ⋯"))
        XCTAssertTrue(disabled.dryRun.enabled)
        XCTAssertEqual(disabled.toggleLabel, "Enable")
    }

    func testRerunOnlyForFailedRuns() {
        XCTAssertTrue(ACP.canRerun(run(.failed, error: "boom")))
        XCTAssertTrue(ACP.canRerun(run(.failed, errorKind: "interrupted")))
        for status: AutomationRunStatus in [.succeeded, .cancelled, .timedOut, .budgetExceeded, .expired, .running,
                                            .waiting, .queued] {
            XCTAssertFalse(ACP.canRerun(run(status)), "\(status)")
        }
        // A dry run is not repeated as a live run.
        XCTAssertFalse(ACP.canRerun(run(.failed, trigger: "dry_run")))
    }

    // MARK: - History

    func testRunHeadline() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        // 2027-01-15 is a Friday; now = 12:00 UTC that day.
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 12)))
        let at = { (day: Int, hour: Int) in
            calendar.date(from: DateComponents(year: 2027, month: 1, day: day, hour: hour)) ?? .distantPast
        }
        let ok = AutomationRun(id: 1, automationID: 7, status: .succeeded, activeMS: 41_000, startedAt: at(15, 9))
        XCTAssertEqual(ACP.runHeadline(ok, now: today, calendar: calendar), "Succeeded · Today 09:00 · 41 s")
        let yesterday = AutomationRun(id: 2, automationID: 7, status: .succeeded, activeMS: 37_000, startedAt: at(14, 9))
        XCTAssertEqual(ACP.runHeadline(yesterday, now: today, calendar: calendar), "Succeeded · Yesterday 09:00 · 37 s")
        let monday = AutomationRun(id: 3, automationID: 7, status: .budgetExceeded, activeMS: 120_000,
                                   startedAt: at(11, 9))
        XCTAssertEqual(ACP.runHeadline(monday, now: today, calendar: calendar), "Budget exceeded · Mon 09:00 · 2 min")
        let older = AutomationRun(id: 4, automationID: 7, status: .failed, activeMS: 3_900_000, startedAt: at(2, 9))
        XCTAssertEqual(ACP.runHeadline(older, now: today, calendar: calendar), "Failed · Jan 2 09:00 · 1 h 5 min")
        let waiting = AutomationRun(id: 5, automationID: 7, status: .waiting, waitingReason: "ask", startedAt: at(15, 9))
        XCTAssertEqual(ACP.runHeadline(waiting, now: today, calendar: calendar), "Waiting for your answer · Today 09:00")
    }

    func testTriggerLabel() {
        XCTAssertEqual(ACP.triggerLabel(run(.succeeded)), "Scheduled")
        XCTAssertEqual(ACP.triggerLabel(run(.succeeded, trigger: "dry_run")), "Dry run")
        XCTAssertEqual(ACP.triggerLabel(run(.succeeded, trigger: "catch_up")), "Caught up after sleep")
        XCTAssertEqual(ACP.triggerLabel(AutomationRun(id: 9, automationID: 7, rerunOf: 3, status: .running)), "Rerun of #3")
    }

    func testStepLine() {
        XCTAssertEqual(ACP.stepLine(AutomationRunStep(kind: "tool", name: "list_emails", resultSummary: "23 messages",
                                                      status: "ok")),
                       "✓ list_emails — 23 messages")
        XCTAssertEqual(ACP.stepLine(AutomationRunStep(kind: "llm", name: "light", status: "ok", inputTokens: 1000,
                                                      outputTokens: 180)),
                       "✓ llm (light) — 1,180 tokens")
        XCTAssertEqual(ACP.stepLine(AutomationRunStep(kind: "output", name: "inbox",
                                                      resultSummary: "\"Mail: 4 need a reply\"", status: "ok")),
                       "✓ inbox card — \"Mail: 4 need a reply\"")
        XCTAssertEqual(ACP.stepLine(AutomationRunStep(kind: "tool", name: "get_email", status: "error", error: "timeout")),
                       "✗ get_email — timeout")
        XCTAssertEqual(ACP.stepLine(AutomationRunStep(kind: "tool", name: "list_jira_issues", status: "denied",
                                                      permission: "jira:read@OPS")),
                       "⊘ list_jira_issues — needs jira:read@OPS")
    }

    func testShellWarningOnlyWithShellEntries() {
        XCTAssertNil(ACP.shellWarning(permissions: ["llm:light", "gmail:read@*"]))
        XCTAssertNotNil(ACP.shellWarning(permissions: ["llm:light", #"shell:"make test""#]))
    }
}

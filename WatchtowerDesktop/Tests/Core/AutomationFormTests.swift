import XCTest
@testable import WatchtowerCore

/// `show --json` / `validate --json` payloads shared by the form and editor
/// center tests (sample data: acme, example.com).
enum AutomationEditFixtures {
    static let recipe = "---\nname: Digest\ntrigger:\n  schedule: \"0 16 * * 5\"\nbudget:\n  tokens: 50000\n---\n"
        + "Summarises the week.\n\n```js\nconst a = 1;\noutput.report({ title: \"t\", body: \"b\" });\n```\n"

    static func showJSON(
        id: Int64 = 7,
        scope: String = "personal",
        approval: String = "h1",
        confirmed: String = "h1",
        contentHash: String = "c1",
        text: String = recipe
    ) throws -> Data {
        let object: [String: Any] = [
            "id": id, "slug": "digest", "scope": scope, "project_id": scope == "personal" ? 0 : 3,
            "path": "/acme/automations/digest.md", "name": "Digest", "description": "Summarises the week.",
            "script": "const a = 1;\n", "recipe_text": text, "trigger_kind": "schedule",
            "trigger_spec": #"{"schedule":"0 16 * * 5"}"#, "permissions": ["jira:read@ACME"], "outputs": ["report"],
            "budget_tokens": 50000, "budget_minutes": 5, "concurrency": 1, "missed_policy": "run_once",
            "pause_timeout_hours": 72, "enabled": true, "runnable": approval == confirmed,
            "needs_confirmation": approval != confirmed, "parse_error": "", "content_hash": contentHash,
            "approval_hash": approval, "confirmed_hash": confirmed, "widening": [String](), "grants": [String](),
            "changes": [String](), "changes_known": true, "changed_by": "", "changed_at": NSNull()
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func detail(scope: String = "personal", approval: String = "h1", confirmed: String = "h1") throws
        -> AutomationDetail {
        try JSONDecoder().decode(AutomationDetail.self,
                                 from: showJSON(scope: scope, approval: approval, confirmed: confirmed))
    }

    static func validateJSON(
        approval: String,
        contentHash: String = "c2",
        widening: [String] = [],
        ok: Bool = true,
        errors: [String] = []
    ) throws -> Data {
        let object: [String: Any] = [
            "ok": ok, "errors": errors, "slug": "digest", "name": "Digest", "scope": "personal",
            "approval_hash": approval, "content_hash": contentHash, "permissions": ["jira:read@ACME"],
            "outputs": ["report"], "widening": widening
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func validated(approval: String, widening: [String] = []) throws -> AutomationsCLI.ValidateResult {
        try JSONDecoder().decode(AutomationsCLI.ValidateResult.self,
                                 from: validateJSON(approval: approval, widening: widening))
    }

    static func grant(_ tool: String, hash: String) -> AutomationToolGrant {
        AutomationToolGrant(automationID: 7, tool: tool, grantHash: hash, grantedAt: Date(timeIntervalSince1970: 0))
    }
}

@MainActor
final class AutomationFormTests: XCTestCase {
    private typealias Fixtures = AutomationEditFixtures

    // MARK: - Save plan

    func testWideningSheetShownOnlyOnWidening() throws {
        let current = try Fixtures.detail()
        let quiet = AutomationSavePlan.make(validated: try Fixtures.validated(approval: "h1"), current: current, grants: [])
        XCTAssertFalse(quiet.needsSheet, "no widening, confirmed, same hash, no grants: Save saves at once")

        let wider = AutomationSavePlan.make(validated: try Fixtures.validated(approval: "h1", widening: ["jira:read@*"]),
                                            current: current, grants: [])
        XCTAssertTrue(wider.needsSheet)
    }

    func testUnconfirmedRecipeAlwaysShowsSheet() throws {
        let plan = AutomationSavePlan.make(validated: try Fixtures.validated(approval: "h1"),
                                           current: try Fixtures.detail(approval: "h1", confirmed: ""), grants: [])
        XCTAssertFalse(plan.wasConfirmed)
        XCTAssertTrue(plan.needsSheet)
    }

    func testAuto03_KeepAutoBoxesUncheckedByDefault() throws {
        let grants = [Fixtures.grant("create_jira_issue", hash: "h1"), Fixtures.grant("add_comment", hash: "h1"),
                      Fixtures.grant("send_slack_message", hash: "h0")]
        let plan = AutomationSavePlan.make(validated: try Fixtures.validated(approval: "h2"), current: try Fixtures.detail(), grants: grants)
        XCTAssertEqual(plan.pausedGrants, ["add_comment", "create_jira_issue"],
                       "the grants active under the current hash, an already paused one left out")
        XCTAssertEqual(plan.keepAuto, [], "no Keep auto box is checked by default")
        XCTAssertTrue(plan.needsSheet)
    }

    /// D26: a trigger, missed, budget or concurrency edit is spliced into the
    /// recipe and changes the approval hash Go returns, so the sheet shows and
    /// the active grants are paused.
    func testScheduleOrBudgetEditShowsSheetAndPausesGrants() throws {
        let edits: [(String, (inout RecipeFrontmatter) -> Void, String)] = [
            ("trigger", { $0.trigger = .schedule("0 16 * * 1-5") }, "  schedule: \"0 16 * * 1-5\"\n"),
            ("missed", { $0.missed = "skip" }, "missed: \"skip\"\n"),
            ("budget tokens", { $0.budgetTokens = 120_000 }, "  tokens: 120000\n"),
            ("budget minutes", { $0.budgetMinutes = 10 }, "  minutes: 10\n"),
            ("concurrency", { $0.concurrency = 2 }, "concurrency: 2\n")
        ]
        for (name, edit, expected) in edits {
            let form = AutomationFormModel(detail: try Fixtures.detail())
            edit(&form.fields)
            XCTAssertTrue(form.renderedText().contains(expected), "\(name) reaches the recipe text")
            XCTAssertTrue(form.renderedText().hasSuffix("```js\nconst a = 1;\noutput.report({ title: \"t\", body: \"b\" });\n```\n"))

            let plan = AutomationSavePlan.make(validated: try Fixtures.validated(approval: "h2"), current: form.detail,
                                               grants: [Fixtures.grant("create_jira_issue", hash: "h1")])
            XCTAssertTrue(plan.needsSheet, name)
            XCTAssertEqual(plan.pausedGrants, ["create_jira_issue"], name)
        }
    }

    func testNameOnlyEditPausesNoGrants() throws {
        let form = AutomationFormModel(detail: try Fixtures.detail())
        form.fields.name = "Weekly digest"
        XCTAssertTrue(form.renderedText().contains("name: \"Weekly digest\"\n"))
        let plan = AutomationSavePlan.make(validated: try Fixtures.validated(approval: "h1"), current: form.detail,
                                           grants: [Fixtures.grant("create_jira_issue", hash: "h1")])
        XCTAssertEqual(plan.pausedGrants, [])
        XCTAssertFalse(plan.needsSheet)
    }

    /// R-P3-5 lifted in P5 part 2 (PROJ-03 amendment, ask #272): the form
    /// edits a workbench recipe like a personal one.
    func testWorkbenchScopeIsEditable() throws {
        let form = AutomationFormModel(detail: try Fixtures.detail(scope: "workbench"))
        form.fields.name = "Changed"
        XCTAssertTrue(form.renderedText().contains("name: \"Changed\"\n"), "the form writes a workbench recipe's fields")
    }

    // MARK: - Form and buffer

    func testFieldEditKeepsScriptEditsFromMonaco() throws {
        let form = AutomationFormModel(detail: try Fixtures.detail())
        let edited = Fixtures.recipe.replacingOccurrences(of: "const a = 1;", with: "const a = 2;")
        form.buffer.pageSent(text: edited, base: form.buffer.revision)
        form.fields.budgetMinutes = 7
        XCTAssertTrue(form.renderedText().contains("const a = 2;"), "the Monaco edit is kept")
        XCTAssertTrue(form.renderedText().contains("  minutes: 7\n"))
        XCTAssertTrue(form.buffer.isDirty)
        XCTAssertEqual(form.buffer.baseContentHash, "c1", "still tied to the loaded file")
    }

    func testFrontmatterEditedInRecipePausesTheForm() throws {
        let form = AutomationFormModel(detail: try Fixtures.detail())
        XCTAssertFalse(form.frontmatterEditedInRecipe)
        form.fields.name = "From the form"
        XCTAssertFalse(form.frontmatterEditedInRecipe, "the form's own splice is not an outside edit")

        let typed = form.renderedText().replacingOccurrences(of: "concurrency: 1", with: "concurrency: 3")
        form.buffer.pageSent(text: typed, base: form.buffer.revision)
        XCTAssertTrue(form.frontmatterEditedInRecipe)
        form.fields.concurrency = 2
        XCTAssertEqual(form.renderedText(), typed, "the form no longer overwrites the frontmatter typed in Monaco")
        XCTAssertEqual(form.problems, [])
    }

    /// A Monaco edit typed before a form change reached the page replaced
    /// the text; it touched only the script, so the form change is spliced back.
    func testFormEditLostToAScriptEditIsSplicedBack() throws {
        let form = AutomationFormModel(detail: try Fixtures.detail())
        let typedBase = form.buffer.revision
        let typed = Fixtures.recipe.replacingOccurrences(of: "const a = 1;", with: "const a = 2;")
        form.fields.name = "From the form"
        form.buffer.pageSent(text: typed, base: typedBase)
        XCTAssertTrue(form.renderedText().contains("name: \"From the form\""), "the form change is applied again")
        XCTAssertTrue(form.renderedText().contains("const a = 2;"), "the script edit is kept")
        XCTAssertFalse(form.frontmatterEditedInRecipe)
        XCTAssertFalse(form.lostFormEdit)
    }

    /// The concurrent Monaco edit changed the settings too: the form pauses
    /// and says its change did not land, never showing it as applied.
    func testFormEditLostToASettingsEditSaysSo() throws {
        let form = AutomationFormModel(detail: try Fixtures.detail())
        let typedBase = form.buffer.revision
        let typed = Fixtures.recipe.replacingOccurrences(of: "name: Digest", with: "name: Typed")
        form.fields.budgetMinutes = 9
        form.buffer.pageSent(text: typed, base: typedBase)
        XCTAssertEqual(form.renderedText(), typed)
        XCTAssertTrue(form.frontmatterEditedInRecipe)
        XCTAssertTrue(form.lostFormEdit)
    }

    func testOutOfRangeValuesAreBlocked() throws {
        let form = AutomationFormModel(detail: try Fixtures.detail())
        XCTAssertEqual(form.problems, [])
        form.fields.budgetTokens = 999
        form.fields.budgetMinutes = 61
        form.fields.concurrency = 5
        form.fields.pauseTimeoutHours = 0
        form.fields.name = " "
        XCTAssertEqual(form.problems.count, 5)
        form.fields = RecipeFrontmatter(detail: form.detail)
        form.fields.trigger = .button(label: String(repeating: "x", count: 25), confirm: false)
        XCTAssertEqual(form.problems, ["The button label must be 1–24 characters."])
    }

    // MARK: - Schedule picker

    func testScheduleChoiceReadsAndWritesCron() throws {
        XCTAssertEqual(ScheduleChoice(cron: "0 9 * * 1-5").repeats, .weekdays)
        XCTAssertEqual(ScheduleChoice(cron: "30 7 * * *").repeats, .daily)
        let weekly = ScheduleChoice(cron: "0 16 * * 5")
        XCTAssertEqual(weekly.repeats, .weekly)
        XCTAssertEqual(weekly.weekday, 5)
        XCTAssertEqual(ScheduleChoice(cron: "15 * * * *").repeats, .hourly)
        XCTAssertEqual(ScheduleChoice(cron: "0 9 1 * *").repeats, .custom)

        var choice = ScheduleChoice(cron: "0 9 * * 1-5")
        choice.hour = 16
        choice.repeats = .weekly
        choice.weekday = 1
        XCTAssertEqual(choice.cron, "0 16 * * 1")
        choice.repeats = .hourly
        choice.minute = 5
        XCTAssertEqual(choice.cron, "5 * * * *")
    }

    func testScheduleNextLine() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        calendar.locale = Locale(identifier: "en_US")
        let fridayNoon = Date(timeIntervalSince1970: 1_792_152_000) // 2026-10-16T12:00:00Z, a Friday
        XCTAssertEqual(ScheduleChoice(cron: "0 9 * * 1-5").nextLine(now: fridayNoon, calendar: calendar),
                       "Next: Mon 09:00 · cron 0 9 * * 1-5")
        XCTAssertEqual(ScheduleChoice(cron: "0 13 * * *").nextLine(now: fridayNoon, calendar: calendar),
                       "Next: today 13:00 · cron 0 13 * * *")
        XCTAssertEqual(ScheduleChoice(cron: "0 9 * * *").nextLine(now: fridayNoon, calendar: calendar),
                       "Next: tomorrow 09:00 · cron 0 9 * * *")
        XCTAssertEqual(ScheduleChoice(cron: "0 9 1 * *").nextLine(now: fridayNoon, calendar: calendar),
                       "Cron: 0 9 1 * * · cron 0 9 1 * *")
    }
}

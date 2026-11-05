import XCTest
@testable import WatchtowerCore

/// The draft column beside the editor chat: what the owner is about to save,
/// from the validated bytes (sample data: acme).
final class AutomationDraftColumnModelTests: XCTestCase {
    private static let recipe = """
    ---
    name: "acme digest"
    trigger:
      schedule: "0 9 * * 1-5"
    missed: "skip"
    concurrency: 2
    permissions:
      - "gmail:read@work"
      - "llm:light"
    outputs:
      - "inbox"
    budget:
      tokens: 40000
      minutes: 5
    ---
    The digest.

    ```js
    output.inbox({title: "Digest"})
    ```

    """

    private static let confirmed = recipe.replacingOccurrences(of: "0 9 * * 1-5", with: "0 8 * * 1-5")

    private static let fullFields = #"{"trigger":"schedule: 0 9 * * 1-5","missed":"skip","concurrency":"2","#
        + #""budget":{"tokens":40000,"minutes":5}}"#

    private func validated(
        text: String = recipe,
        ok: Bool = true,
        errors: [String] = [],
        widening: [String] = [],
        changes: String = "[]",
        changesKnown: Bool = true,
        feeds: Bool = false,
        fields: String? = fullFields,
        permissions: [String] = ["gmail:read@work", "llm:light"],
        outputs: String = #"["inbox"]"#,
        addsLLM: String = ""
    ) throws -> AutomationsCLI.ValidateResult {
        let errorsJSON = String(data: try JSONSerialization.data(withJSONObject: errors), encoding: .utf8) ?? "[]"
        let wideningJSON = String(data: try JSONSerialization.data(withJSONObject: widening), encoding: .utf8) ?? "[]"
        let permissionsJSON = String(data: try JSONSerialization.data(withJSONObject: permissions),
                                     encoding: .utf8) ?? "[]"
        let fieldsJSON = fields.map { #","fields":\#($0)"# } ?? ""
        let hash = AutomationDraftColumnModel.contentHash(text)
        let json = #"{"ok":\#(ok),"errors":\#(errorsJSON),"slug":"acme-digest","name":"acme digest","#
            + #""scope":"personal","approval_hash":"h2","content_hash":"\#(hash)","#
            + #""permissions":\#(permissionsJSON),"outputs":\#(outputs),"#
            + #""widening":\#(wideningJSON),"feeds_sources_to_llm":\#(feeds),"#
            + #""changes":\#(changes),"changes_known":\#(changesKnown)\#(fieldsJSON)"#
            + (addsLLM.isEmpty ? "" : #","adds_llm":\#(addsLLM)"#) + "}"
        return try JSONDecoder().decode(AutomationsCLI.ValidateResult.self, from: Data(json.utf8))
    }

    private func entry(text: String) throws -> AutomationDraftEntry {
        let line: [String: Any] = [
            "recipe_text": text,
            "result": [
                "ok": true, "errors": [],
                "manifest": ["name": "acme digest", "slug": "acme-digest", "trigger_kind": "schedule",
                             "trigger": "0 9 * * 1-5", "permissions": ["gmail:read@work"], "outputs": ["inbox"],
                             "budget_tokens": 40000, "budget_minutes": 5],
                "dry_run": [
                    "steps": [["seq": 1, "kind": "tool", "name": "list_emails", "status": "ok", "args": "{}",
                               "result": "17", "permission": "gmail:read@work", "error": "", "tokens": 0]],
                    "tokens": 1200, "status": "succeeded", "error": ""
                ]
            ],
            "at": "2026-10-20T09:00:00Z"
        ]
        let data = try JSONSerialization.data(withJSONObject: line)
        return try JSONDecoder().decode(AutomationDraftEntry.self, from: data)
    }

    private func model(
        text: String = recipe,
        validated: AutomationsCLI.ValidateResult?,
        isChecking: Bool = false,
        entry: AutomationDraftEntry? = nil,
        confirmedText: String? = nil,
        isNew: Bool = true,
        plan: AutomationSavePlan? = nil,
        saved: AutomationDraftColumnModel.Saved? = nil,
        now: Date = Date()
    ) -> AutomationDraftColumnModel {
        AutomationDraftColumnModel(text: text, validated: validated, isChecking: isChecking, newestChatEntry: entry,
                                   confirmedText: confirmedText, isNew: isNew, plan: plan, saved: saved, now: now)
    }

    func testNewRecipeShowsNoNewMarksAndHasNoChanges() throws {
        // Nothing was ever confirmed: "New since you confirmed" would sit on every line.
        let m = model(validated: try validated(widening: ["gmail:read@work", "llm:light"]))
        XCTAssertEqual(m.status, .ready)
        XCTAssertEqual(m.mayDo.count, 2)
        XCTAssertFalse(m.mayDo.contains(where: \.isNew))
        XCTAssertEqual(m.mayDo.map(\.text), ["gmail:read@work", "llm:light"].map(AutomationCardPresentation.permissionLine))
        XCTAssertEqual(m.sends, [AutomationCardPresentation.outputLine("inbox")])
        XCTAssertEqual(m.changes, [])
        XCTAssertNil(m.recipeDiff)
        XCTAssertEqual(m.recipeText, Self.recipe)
        XCTAssertEqual(AutomationDraftColumnModel.newMark, "New since you confirmed")
        // When, Each run, Missed and Concurrency come from `fields`.
        XCTAssertTrue(m.showsAllFields)
        XCTAssertNil(m.placeholder)
        XCTAssertEqual(m.when, "Every weekday at 09:00")
        XCTAssertEqual(m.whenDetail, "Your local time · if the Mac was asleep, skips that time")
        XCTAssertEqual(m.eachRun, "40,000 tokens · 5 min")
        XCTAssertEqual(m.missedAndConcurrency, "Missed while asleep: skip · Up to 2 runs at a time")
    }

    func testEditShowsChangesAndWideningOnly() throws {
        let changes = #"[{"field":"trigger","old":"{\"schedule\":\"0 8 * * 1-5\"}","new":"{\"schedule\":\"0 9 * * 1-5\"}"}]"#
        let m = model(validated: try validated(widening: ["gmail:read@work"], changes: changes),
                      confirmedText: Self.confirmed, isNew: false)
        XCTAssertEqual(m.mayDo.map(\.isNew), [true, false])
        XCTAssertEqual(m.changes.count, 1)
        XCTAssertTrue(m.changes[0].hasPrefix("Schedule "), m.changes[0])
        XCTAssertTrue(m.changes[0].contains(" → "), m.changes[0])
        let diff = try XCTUnwrap(m.recipeDiff)
        XCTAssertFalse(diff.isIdentical)
    }

    func testEditOfANeverConfirmedRecipeShowsNoNewMarks() throws {
        let m = model(validated: try validated(widening: ["gmail:read@work"]), confirmedText: nil, isNew: false)
        XCTAssertEqual(m.mayDo.count, 2)
        XCTAssertFalse(m.mayDo.contains(where: \.isNew))
    }

    func testUnknownChangesSaySo() throws {
        let m = model(validated: try validated(changesKnown: false), confirmedText: Self.confirmed, isNew: false)
        XCTAssertEqual(m.changes, [AutomationChangePresentation.unknownChanges])
    }

    func testDryRunShownOnlyForTheSameText() throws {
        let same = model(validated: try validated(), entry: try entry(text: Self.recipe))
        XCTAssertFalse(same.dryRunLines.isEmpty)
        XCTAssertNil(same.dryRunNote)

        let edited = Self.recipe + "\n"
        let other = model(text: edited, validated: try validated(text: edited), entry: try entry(text: Self.recipe))
        XCTAssertEqual(other.dryRunLines, [])
        XCTAssertEqual(other.sessions, [])
        XCTAssertEqual(other.dryRunNote, AutomationDraftColumnModel.notDryRunNote)
        XCTAssertEqual(AutomationDraftColumnModel.notDryRunNote, "Not dry-run since the last change.")

        let none = model(validated: try validated())
        XCTAssertEqual(none.dryRunNote, AutomationDraftColumnModel.notDryRunNote)
    }

    func testCheckingStatus() throws {
        XCTAssertEqual(model(validated: try validated(), isChecking: true).status, .checking)
        XCTAssertEqual(model(validated: try validated(ok: false, errors: ["x"]), isChecking: true).status, .checking)
        XCTAssertEqual(model(validated: nil, isChecking: true).status, .checking)
        // Not checked yet, or checked for other bytes: nothing ready to save either.
        XCTAssertEqual(model(validated: nil).status, .checking)
        XCTAssertEqual(model(text: Self.recipe + "x", validated: try validated()).status, .checking)
    }

    /// While checking, no box claims a value: It may and Sends list nothing
    /// and the rest say "Checking…".
    func testCheckingShowsNoValues() throws {
        for m in [model(validated: nil, isChecking: true), model(validated: try validated(), isChecking: true),
                  model(text: Self.recipe + "x", validated: try validated())] {
            XCTAssertFalse(m.showsAllFields)
            XCTAssertEqual(m.placeholder, AutomationDraftColumnModel.checkingLine)
            XCTAssertEqual(m.when, AutomationDraftColumnModel.checkingLine)
            XCTAssertEqual(m.eachRun, AutomationDraftColumnModel.checkingLine)
            XCTAssertEqual(m.mayDo, [])
            XCTAssertEqual(m.sends, [])
            XCTAssertEqual(m.changes, [])
        }
    }

    func testFailedCheckWithoutAResultIsNotChecking() throws {
        // The CLI did not answer: the footer says why, the column must not say "Checking…".
        let failed = AutomationDraftColumnModel(text: Self.recipe, validated: nil, isChecking: false,
                                                newestChatEntry: nil, confirmedText: nil, isNew: true, plan: nil,
                                                checkFailed: true)
        XCTAssertEqual(failed.status, .invalid)
        XCTAssertEqual(failed.errors, [])
        XCTAssertEqual(failed.placeholder, AutomationDraftColumnModel.unreadableLine)
        XCTAssertFalse(failed.showsAllFields)
        // Still checking while a new check runs.
        let rechecking = AutomationDraftColumnModel(text: Self.recipe, validated: nil, isChecking: true,
                                                    newestChatEntry: nil, confirmedText: nil, isNew: true, plan: nil,
                                                    checkFailed: true)
        XCTAssertEqual(rechecking.status, .checking)
    }

    func testInvalidShowsErrors() throws {
        let m = model(validated: try validated(ok: false, errors: ["line 3: trigger is required"]))
        XCTAssertEqual(m.status, .invalid)
        XCTAssertEqual(m.errors, ["line 3: trigger is required"])
        XCTAssertEqual(model(validated: try validated()).errors, [])
    }

    func testPausedGrantsAndLLMWarningFromPlan() throws {
        let valid = try validated(feeds: true)
        let plan = AutomationSavePlan(validated: valid, wasConfirmed: true,
                                      pausedGrants: ["create_idea", "send_slack_message"],
                                      llmWarningTools: ["send_slack_message"], currentApprovalHash: "h1")
        let m = model(validated: valid, confirmedText: Self.confirmed, isNew: false, plan: plan)
        XCTAssertEqual(m.pausedGrants, ["create_idea", "send_slack_message"])
        XCTAssertEqual(m.llmWarning,
                       AutomationLLMWarning.line(feedsSourcesToLLM: true, tools: ["send_slack_message"]))

        let without = model(validated: valid)
        XCTAssertEqual(without.pausedGrants, [])
        XCTAssertNil(without.llmWarning)
    }

    /// A check without `fields` (an older CLI) or with `{}` cannot show
    /// every hashed field: the boxes say so and nothing may be saved.
    func testMissingOrEmptyFieldsCannotShowAll() throws {
        for fields in [nil, "{}", #"{"trigger":"manual"}"#] as [String?] {
            let m = model(validated: try validated(fields: fields))
            XCTAssertFalse(m.showsAllFields, fields ?? "nil")
            XCTAssertEqual(m.status, .ready)
            XCTAssertEqual(m.placeholder, AutomationDraftColumnModel.unreadableLine)
            XCTAssertEqual(m.when, AutomationDraftColumnModel.unreadableLine)
            XCTAssertNil(m.whenDetail)
            XCTAssertEqual(m.eachRun, AutomationDraftColumnModel.unreadableLine)
            XCTAssertEqual(m.missedAndConcurrency, AutomationDraftColumnModel.unreadableLine)
            XCTAssertEqual(m.mayDo, [])
        }
        let invalid = model(validated: try validated(ok: false, errors: ["no frontmatter"], fields: "{}"))
        XCTAssertFalse(invalid.showsAllFields)
        XCTAssertEqual(invalid.when, AutomationDraftColumnModel.unreadableLine)
    }

    /// Each trigger line Go writes, in the Draft panel's words.
    func testTriggerLinesInWords() throws {
        func when(_ trigger: String) throws -> (String, String?) {
            let fields = #"{"trigger":"\#(trigger)","missed":"run_once","concurrency":"1","#
                + #""budget":{"tokens":1000,"minutes":1}}"#
            let m = model(validated: try validated(fields: fields))
            return (m.when, m.whenDetail)
        }
        let schedule = try when("schedule: 0 9 * * 1-5")
        XCTAssertEqual(schedule.0, "Every weekday at 09:00")
        XCTAssertEqual(schedule.1, AutomationDraftPanelModel.missedDetail(skips: false))
        let event = try when(#"event: slack.new_messages where account=\"a\", channel=\"b\""#)
        XCTAssertEqual(event.0, "On new Slack messages")
        XCTAssertEqual(event.1, #"Where account="a", channel="b""#)
        XCTAssertEqual(try when("event: gmail.new_messages").1, nil)
        XCTAssertEqual(try when("button").0, "Button")
        XCTAssertEqual(try when("button (asks before running)").0, "Button, asks before running")
        XCTAssertEqual(try when("manual").0, "Only when you run it")
        XCTAssertEqual(model(validated: try validated(fields: #"{"trigger":"manual","missed":"run_once","#
            + #""concurrency":"1","budget":{"tokens":1000,"minutes":1}}"#)).missedAndConcurrency,
                       "Missed while asleep: run once · One run at a time")
    }

    /// Board #560: a `shell:` entry gets the warning that confirming covers
    /// the command text only, in It may, on every screen that confirms.
    func testShellPermissionShowsTheShellWarning() throws {
        let shell = ["shell:\"make test\"", "llm:light"]
        let m = model(validated: try validated(permissions: shell))
        XCTAssertTrue(m.showsAllFields)
        XCTAssertEqual(m.shellWarning, AutomationCardPresentation.shellWarning(permissions: shell))
        XCTAssertNotNil(m.shellWarning)
        XCTAssertNil(model(validated: try validated()).shellWarning)
        // No value is claimed while the bytes are being checked.
        XCTAssertNil(model(validated: try validated(permissions: shell), isChecking: true).shellWarning)
    }

    /// #559 on a confirm: the saved recipe's `llm_auto_writes` (auto grants,
    /// active or paused, on External tools) warn even with nothing paused by
    /// this press, merged with the plan's paused ones.
    func testConfirmOfTheSavedTextShowsItsLLMAutoWrites() throws {
        let valid = try validated(feeds: true)
        let saved = AutomationDraftColumnModel.Saved(changedBy: "", changedAt: nil, needsConfirmation: true,
                                                     llmAutoWrites: ["send_slack_message"])
        let m = model(validated: valid, confirmedText: Self.confirmed, isNew: false, saved: saved)
        XCTAssertEqual(m.pausedGrants, [])
        XCTAssertEqual(m.llmWarning,
                       AutomationLLMWarning.line(feedsSourcesToLLM: true, tools: ["send_slack_message"]))

        let plan = AutomationSavePlan(validated: valid, wasConfirmed: true, pausedGrants: ["create_jira_issue"],
                                      llmWarningTools: ["create_jira_issue"], currentApprovalHash: "h1")
        let both = model(validated: valid, confirmedText: Self.confirmed, isNew: false, plan: plan, saved: saved)
        XCTAssertEqual(both.llmWarning, AutomationLLMWarning.line(
            feedsSourcesToLLM: true, tools: ["create_jira_issue", "send_slack_message"]))

        // Text that does not feed its sources to llm() warns of nothing.
        let quiet = model(validated: try validated(), confirmedText: Self.confirmed, isNew: false, saved: saved)
        XCTAssertNil(quiet.llmWarning)
    }

    /// The Changed box of a confirm says who made the change.
    func testConfirmShowsWhoChangedIt() throws {
        let now = Date(timeIntervalSince1970: 1_792_152_000)
        let changes = #"[{"field":"script","old":"","new":""}]"#
        let saved = AutomationDraftColumnModel.Saved(changedBy: "", changedAt: now.addingTimeInterval(-600),
                                                     needsConfirmation: true, llmAutoWrites: [])
        let m = model(validated: try validated(changes: changes), confirmedText: Self.confirmed, isNew: false,
                      saved: saved, now: now)
        XCTAssertEqual(m.changes, ["Script changed"])
        XCTAssertEqual(m.authorLine, "Changed outside Watchtower · 10 min ago")
        // The owner's own edit (no saved text shown) or a confirmed recipe names no author.
        XCTAssertNil(model(validated: try validated(changes: changes), confirmedText: Self.confirmed,
                           isNew: false, now: now).authorLine)
        let confirmed = AutomationDraftColumnModel.Saved(changedBy: "assistant", changedAt: nil,
                                                         needsConfirmation: false, llmAutoWrites: [])
        XCTAssertNil(model(validated: try validated(changes: changes), confirmedText: Self.confirmed,
                           isNew: false, saved: confirmed, now: now).authorLine)
    }

    func testAuthorLine() {
        let now = Date(timeIntervalSince1970: 1_792_152_000)
        let tenMinutesAgo = now.addingTimeInterval(-600)
        XCTAssertEqual(AutomationChangePresentation.authorLine(changedBy: "assistant", changedAt: tenMinutesAgo, now: now),
                       "Changed by the assistant in the chat · 10 min ago")
        XCTAssertEqual(AutomationChangePresentation.authorLine(changedBy: "", changedAt: tenMinutesAgo, now: now),
                       "Changed outside Watchtower · 10 min ago")
        XCTAssertEqual(AutomationChangePresentation.authorLine(changedBy: "", changedAt: nil, now: now),
                       "Changed outside Watchtower")
    }

    // MARK: - Inbox builder A: the AI-step flag and the Inbox cards box

    /// `adds_llm` of the bytes on screen drives the footer's AI-step line;
    /// an older CLI without it, a check of other bytes or a recipe that does
    /// not validate says nothing.
    func testAddsLLMFromTheCheckOfTheseBytes() throws {
        XCTAssertTrue(model(validated: try validated(addsLLM: "true")).addsLLM)
        XCTAssertFalse(model(validated: try validated(addsLLM: "false")).addsLLM)
        XCTAssertFalse(model(validated: try validated()).addsLLM, "older CLI: no adds_llm key")
        XCTAssertFalse(model(text: Self.confirmed, validated: try validated(addsLLM: "true")).addsLLM, "other bytes")
        XCTAssertFalse(model(validated: try validated(addsLLM: "true"), isChecking: true).addsLLM)
        XCTAssertFalse(model(validated: try validated(ok: false, errors: ["bad"], fields: "{}", addsLLM: "true")).addsLLM)
    }

    /// `fields.artifacts` (hashed, AUTO-06) is shown on **When it runs**:
    /// living as kept current, feed — and an older CLI's missing key — as a
    /// new card each run; a recipe with no Inbox card has no box.
    func testArtifactsLine() throws {
        let living = #"{"trigger":"schedule: 0 9 * * 1-5","missed":"skip","concurrency":"1","artifacts":"living","#
            + #""budget":{"tokens":40000,"minutes":5}}"#
        let feed = living.replacingOccurrences(of: "living", with: "feed")
        XCTAssertEqual(model(validated: try validated(fields: living)).artifacts, "One card per key, kept current")
        XCTAssertEqual(model(validated: try validated(fields: feed)).artifacts, "A new card each run")
        XCTAssertEqual(model(validated: try validated()).artifacts, "A new card each run", "older CLI: feed")
        XCTAssertNil(model(validated: try validated(fields: feed, outputs: #"["report"]"#)).artifacts)
        XCTAssertNil(model(validated: nil, isChecking: true).artifacts)
        // Artifacts is not needed to show every field: an older CLI still saves.
        XCTAssertTrue(model(validated: try validated()).showsAllFields)
    }

    /// The editor's footer carries the shell (#560), #559 and AI-step
    /// warnings: `Warnings` is built from the column alone, so the footer
    /// drawn under every step shows the same lines; in the steps view the
    /// column's boxes no longer show the first two.
    func testFooterWarningsComeFromTheColumn() throws {
        let saved = AutomationDraftColumnModel.Saved(changedBy: "", changedAt: nil, needsConfirmation: false,
                                                     llmAutoWrites: ["send_slack_message"])
        let all = model(validated: try validated(feeds: true, permissions: ["shell:\"make test\"", "llm:light"],
                                                 addsLLM: "true"),
                        isNew: false, saved: saved)
        let warnings = AutomationDraftFooter.Warnings(column: all, dryRunTokens: 5800)
        XCTAssertEqual(warnings.shell, AutomationCardPresentation.shellWarning(permissions: ["shell:\"make test\""]))
        XCTAssertEqual(warnings.llm, AutomationLLMWarning.line(feedsSourcesToLLM: true, tools: ["send_slack_message"]))
        XCTAssertNotNil(warnings.llm)
        XCTAssertEqual(warnings.aiStep,
                       "This change adds an AI step: every run will use the model. This dry run used 5,800 tokens.")

        let none = AutomationDraftFooter.Warnings(column: model(validated: try validated()), dryRunTokens: 5800)
        XCTAssertNil(none.shell)
        XCTAssertNil(none.llm)
        XCTAssertNil(none.aiStep)
    }
}

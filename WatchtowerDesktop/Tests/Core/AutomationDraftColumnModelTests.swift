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
        fields: String? = fullFields
    ) throws -> AutomationsCLI.ValidateResult {
        let errorsJSON = String(data: try JSONSerialization.data(withJSONObject: errors), encoding: .utf8) ?? "[]"
        let wideningJSON = String(data: try JSONSerialization.data(withJSONObject: widening), encoding: .utf8) ?? "[]"
        let fieldsJSON = fields.map { #","fields":\#($0)"# } ?? ""
        let hash = AutomationDraftColumnModel.contentHash(text)
        let json = #"{"ok":\#(ok),"errors":\#(errorsJSON),"slug":"acme-digest","name":"acme digest","#
            + #""scope":"personal","approval_hash":"h2","content_hash":"\#(hash)","#
            + #""permissions":["gmail:read@work","llm:light"],"outputs":["inbox"],"#
            + #""widening":\#(wideningJSON),"feeds_sources_to_llm":\#(feeds),"#
            + #""changes":\#(changes),"changes_known":\#(changesKnown)\#(fieldsJSON)}"#
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
        plan: AutomationSavePlan? = nil
    ) -> AutomationDraftColumnModel {
        AutomationDraftColumnModel(text: text, validated: validated, isChecking: isChecking, newestChatEntry: entry,
                                   confirmedText: confirmedText, isNew: isNew, plan: plan)
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
        let event = try when("event: slack.new_messages where account=a, channel=b")
        XCTAssertEqual(event.0, "On new Slack messages")
        XCTAssertEqual(event.1, "Where account=a, channel=b")
        XCTAssertEqual(try when("event: gmail.new_messages").1, nil)
        XCTAssertEqual(try when("button").0, "Button")
        XCTAssertEqual(try when("button (asks before running)").0, "Button, asks before running")
        XCTAssertEqual(try when("manual").0, "Only when you run it")
        XCTAssertEqual(model(validated: try validated(fields: #"{"trigger":"manual","missed":"run_once","#
            + #""concurrency":"1","budget":{"tokens":1000,"minutes":1}}"#)).missedAndConcurrency,
                       "Missed while asleep: run once · One run at a time")
    }
}

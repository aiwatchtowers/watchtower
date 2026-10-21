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

    private func validated(
        ok: Bool = true,
        errors: [String] = [],
        widening: [String] = [],
        changes: String = "[]",
        changesKnown: Bool = true,
        feeds: Bool = false
    ) throws -> AutomationsCLI.ValidateResult {
        let errorsJSON = String(data: try JSONSerialization.data(withJSONObject: errors), encoding: .utf8) ?? "[]"
        let wideningJSON = String(data: try JSONSerialization.data(withJSONObject: widening), encoding: .utf8) ?? "[]"
        let json = #"{"ok":\#(ok),"errors":\#(errorsJSON),"slug":"acme-digest","name":"acme digest","#
            + #""scope":"personal","approval_hash":"h2","content_hash":"c2","#
            + #""permissions":["gmail:read@work","llm:light"],"outputs":["inbox"],"#
            + #""widening":\#(wideningJSON),"feeds_sources_to_llm":\#(feeds),"#
            + #""changes":\#(changes),"changes_known":\#(changesKnown)}"#
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

    func testNewRecipeMarksEveryPermissionNewAndHasNoChanges() throws {
        let m = model(validated: try validated())
        XCTAssertEqual(m.status, .ready)
        XCTAssertEqual(m.mayDo.count, 2)
        XCTAssertTrue(m.mayDo.allSatisfy(\.isNew))
        XCTAssertEqual(m.mayDo.map(\.text), ["gmail:read@work", "llm:light"].map(AutomationCardPresentation.permissionLine))
        XCTAssertEqual(m.sends, [AutomationCardPresentation.outputLine("inbox")])
        XCTAssertEqual(m.changes, [])
        XCTAssertNil(m.recipeDiff)
        XCTAssertEqual(m.recipeText, Self.recipe)
        XCTAssertEqual(AutomationDraftColumnModel.newMark, "New since you confirmed")
        // When, Each run, Missed and Concurrency come from the text's frontmatter.
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

    func testUnknownChangesSaySo() throws {
        let m = model(validated: try validated(changesKnown: false), confirmedText: Self.confirmed, isNew: false)
        XCTAssertEqual(m.changes, [AutomationChangePresentation.unknownChanges])
    }

    func testDryRunShownOnlyForTheSameText() throws {
        let same = model(validated: try validated(), entry: try entry(text: Self.recipe))
        XCTAssertFalse(same.dryRunLines.isEmpty)
        XCTAssertNil(same.dryRunNote)

        let edited = Self.recipe + "\n"
        let other = model(text: edited, validated: try validated(), entry: try entry(text: Self.recipe))
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
        // Not checked yet: nothing ready to save either.
        XCTAssertEqual(model(validated: nil).status, .checking)
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

    /// The column reads `When` and the limits from the text itself: what
    /// `RecipeFrontmatter.render` writes reads back as the same fields.
    func testFrontmatterReadsWhatRenderWrites() {
        let fields = [
            RecipeFrontmatter(name: #"Mail: "triage" # weekly \ done — ok"#, trigger: .schedule("30 8 * * 1-5"),
                              missed: "skip", concurrency: 2, permissions: ["gmail:read@work", "llm:light"],
                              outputs: ["inbox", "report"], budgetTokens: 120_000, budgetMinutes: 10,
                              pauseTimeoutHours: 24),
            RecipeFrontmatter(name: "Release", trigger: .button(label: "Release", confirm: true)),
            RecipeFrontmatter(name: "Mail", trigger: .event(type: "gmail.new_messages", where: ["account": "work"])),
            RecipeFrontmatter(name: "Manual", trigger: .manual)
        ]
        for f in fields {
            XCTAssertEqual(RecipeFrontmatter.read(RecipeFrontmatter.render(f) + "body\n"), f)
        }
        XCTAssertNil(RecipeFrontmatter.read("no frontmatter"))
        XCTAssertNil(RecipeFrontmatter.read("---\nname: x\n---\n"), "no trigger")
    }

    /// Hand-written shapes: plain scalars, comments, inline lists.
    func testFrontmatterReadsHandWrittenShapes() throws {
        let text = "---\nname: acme digest # note\ntrigger:\n  schedule: '0 9 * * *'\n"
            + "permissions: [gmail:read@work, \"llm:light\"]\noutputs: []\n---\n"
        let f = try XCTUnwrap(RecipeFrontmatter.read(text))
        XCTAssertEqual(f.name, "acme digest")
        XCTAssertEqual(f.trigger, .schedule("0 9 * * *"))
        XCTAssertEqual(f.permissions, ["gmail:read@work", "llm:light"])
        XCTAssertEqual(f.budgetTokens, 50000)
        XCTAssertEqual(f.missed, "run_once")
    }

    func testUnreadableFrontmatterSaysSo() throws {
        let m = model(text: "not a recipe", validated: try validated(ok: false, errors: ["no frontmatter"]))
        XCTAssertEqual(m.when, AutomationDraftColumnModel.unreadableWhen)
        XCTAssertNil(m.whenDetail)
    }
}

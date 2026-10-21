import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The automation editor before a save: the draft column of an edit, and a
/// pending `save_automation` card with its scope line and "Sessions it
/// starts" (one prompt long enough to fold, one clipped); the New automation
/// panel; the template panel.
@MainActor
enum AutomationShotFixtures {
    private static let recipe = "---\nname: \"Release button\"\ntrigger:\n  button: \"Release\"\n---\n"

    private static let steps: [[String: Any]] = [
        ["seq": 1, "kind": "session", "name": "claude", "status": "dry_run",
         "args": #"{"agent":"claude","prompt":"Run /release for acme. Cut the version, tag it and write the notes; "#
             + #"when the build is green, publish the release and "#
             + #"post the notes to #releases, then report the version number.","title":"Release"}"#,
         "result": "", "permission": "session:start@claude", "error": "", "tokens": 0],
        ["seq": 2, "kind": "session", "name": "claude", "status": "dry_run",
         "args": #"{"agent":"claude","prompt":"Check the rel"#, "result": "", "permission": "session:start@claude",
         "error": "", "tokens": 0],
        ["seq": 3, "kind": "output", "name": "report", "status": "dry_run", "args": #"{"title":"Release"}"#,
         "result": "", "permission": "", "error": "", "tokens": 0]
    ]

    private static func cacheLine() throws -> String {
        let entry: [String: Any] = [
            "recipe_text": recipe,
            "result": [
                "ok": true, "errors": [],
                "manifest": ["name": "Release button", "slug": "release-button", "trigger_kind": "button",
                             "trigger": "Release", "permissions": ["session:start@claude"], "outputs": ["report"],
                             "budget_tokens": 20000, "budget_minutes": 30],
                "dry_run": ["steps": steps, "tokens": 0, "status": "succeeded", "error": ""]
            ],
            "at": "2026-10-20T09:00:00Z"
        ]
        let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private static let digest = """
    ---
    name: "acme digest"
    trigger:
      schedule: "0 9 * * 1-5"
    missed: "skip"
    permissions:
      - "gmail:read@work"
      - "llm:light"
    outputs:
      - "inbox"
    budget:
      tokens: 40000
      minutes: 5
    ---
    Summarises the morning mail.

    ```js
    const mail = tool("list_emails", {account: "work"})
    output.inbox({title: "Digest", body: llm("Summarise", mail)})
    ```

    """

    /// The draft column on an edit of "acme digest": one widening, one
    /// change line and a dry run of the same text.
    static func draftColumn() -> AnyView {
        do {
            let changes = #"[{"field":"trigger","old":"{\"schedule\":\"0 8 * * 1-5\"}","#
                + #""new":"{\"schedule\":\"0 9 * * 1-5\"}"}]"#
            let hash = AutomationDraftColumnModel.contentHash(digest)
            let json = #"{"ok":true,"errors":[],"slug":"acme-digest","name":"acme digest","scope":"personal","#
                + #""approval_hash":"h2","content_hash":"\#(hash)","permissions":["gmail:read@work","llm:light"],"#
                + #""outputs":["inbox"],"widening":["gmail:read@work"],"changes":\#(changes),"changes_known":true,"#
                + #""fields":{"trigger":"schedule: 0 9 * * 1-5","missed":"skip","concurrency":"1","#
                + #""budget":{"tokens":40000,"minutes":5}}}"#
            let validated = try JSONDecoder().decode(AutomationsCLI.ValidateResult.self, from: Data(json.utf8))
            let entry: [String: Any] = [
                "recipe_text": digest,
                "result": [
                    "ok": true, "errors": [],
                    "manifest": ["name": "acme digest", "slug": "acme-digest", "trigger_kind": "schedule",
                                 "trigger": "0 9 * * 1-5", "permissions": ["gmail:read@work", "llm:light"],
                                 "outputs": ["inbox"], "budget_tokens": 40000, "budget_minutes": 5],
                    "dry_run": [
                        "steps": [
                            ["seq": 1, "kind": "tool", "name": "list_emails", "status": "ok", "args": "{}",
                             "result": "17", "permission": "gmail:read@work", "error": "", "tokens": 0],
                            ["seq": 2, "kind": "llm", "name": "light", "status": "ok", "args": "{}",
                             "result": "", "permission": "llm:light", "error": "", "tokens": 1200],
                            ["seq": 3, "kind": "output", "name": "inbox", "status": "dry_run",
                             "args": #"{"title":"Digest"}"#, "result": "", "permission": "", "error": "",
                             "tokens": 0]
                        ],
                        "tokens": 1200, "status": "succeeded", "error": ""
                    ]
                ],
                "at": "2026-10-20T09:00:00Z"
            ]
            let newest = try JSONDecoder().decode(AutomationDraftEntry.self,
                                                  from: try JSONSerialization.data(withJSONObject: entry))
            let confirmed = digest.replacingOccurrences(of: "0 9 * * 1-5", with: "0 8 * * 1-5")
            let model = AutomationDraftColumnModel(text: digest, validated: validated, isChecking: false,
                                                   newestChatEntry: newest, confirmedText: confirmed, isNew: false,
                                                   plan: nil)
            return AnyView(AutomationDraftColumn(model: model, keepAuto: .constant([])) {})
        } catch {
            return failure(error)
        }
    }

    static func saveCard() -> AnyView {
        do {
            let args: [String: Any] = [
                "scope": "workbench", "workbench_id": 3, "path": "/acme/.watchtower/automations/release-button.md",
                "name": "Release button", "slug": "release-button", "trigger_kind": "button",
                "trigger_spec": ["button": ["label": "Release"]], "permissions": ["session:start@claude"],
                "outputs": ["report"], "widening": ["session:start@claude"], "budget_tokens": 20000,
                "budget_minutes": 30, "is_new": true, "recipe_text": recipe, "previous_recipe_text": "",
                "dry_run_summary": "Starts one release session, then reports its summary."
            ]
            let json = try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8))
            let action = AgentAction(row: Row([
                "id": 1, "tool": "save_automation", "args_json": json, "reason": "a Release button",
                "status": "pending", "turn_id": "t1"
            ]))
            let sessions = AutomationDraftPanelModel.dryRunSessions(inCache: try cacheLine())
            return AnyView(AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {},
                                               onRetry: {}, latestDraftText: recipe, draftSessions: sessions))
        } catch {
            return failure(error)
        }
    }

    /// The five templates in `automations templates --json` order.
    private static let templatesJSON = #"""
    [{"name":"new-mail-summary","title":"New mail summary","description":"Sums up new mail.","scope":"personal",
      "trigger_text":"On new Gmail","permissions":["reads your mail"],"outputs":["inbox"]},
     {"name":"pr-review-rounds","title":"PR review rounds","description":"Review rounds.","scope":"workbench",
      "trigger_text":"Weekdays 10:00, 16:00","permissions":["starts agent sessions"],"outputs":["inbox"]},
     {"name":"jira-state-report","title":"Jira state report","description":"Weekly.","scope":"personal",
      "trigger_text":"Mondays 09:00","permissions":["reads Jira"],"outputs":["report"]},
     {"name":"team-performance-report","title":"Team performance report","description":"Weekly.",
      "scope":"personal","trigger_text":"Fridays 17:00","permissions":["reads Jira and Slack"],"outputs":["report"]},
     {"name":"release-buttons","title":"Release and deploy buttons","description":"Buttons.","scope":"workbench",
      "trigger_text":"Button: Release","permissions":["runs a shell command"],"outputs":["report"]}]
    """#

    private static let acme = AutomationScopeChoice.workbench(id: 3, name: "acme", folder: "/work/acme")

    /// The New automation panel: Personal and two workbenches, the five
    /// templates; `fixedScope` acme is a workbench's **New Automation…**.
    static func newPanel(fixedToAcme: Bool) -> AnyView {
        do {
            let templates = try JSONDecoder().decode([AutomationTemplate].self, from: Data(templatesJSON.utf8))
            let scopes: [AutomationScopeChoice] = [
                .personal, acme, .workbench(id: 4, name: "acme-docs", folder: "/work/acme-docs")
            ]
            let flow = AutomationNewFlow(fixedScope: fixedToAcme ? acme : nil)
            return AnyView(AutomationNewPanel(flow: flow, scopes: scopes, templates: templates) { _, _ in })
        } catch {
            return failure(error)
        }
    }

    private static let stateReport = """
    ---
    name: "Jira state report"
    trigger:
      schedule: "0 9 * * 1"
    permissions:
      - "jira:read"
      - "llm:light"
    outputs:
      - "report"
      - "briefing"
    budget:
      tokens: 60000
      minutes: 10
    ---
    Every Monday, a report on your active Jira projects.

    ```js
    const issues = tool("list_jira_issues", {})
    output.report({title: "Jira state", body: llm("Group by state", issues)})
    ```

    """

    /// The template panel on `jira-state-report`: PROJECT empty (placeholder
    /// PAY), one note, the rendered file's column (a FakeCLIRunner answers
    /// `--render`).
    static func templatePanel() -> AnyView {
        do {
            let templateJSON = #"{"name":"jira-state-report","title":"Jira state report","#
                + #""description":"Every Monday, a report on your active Jira projects: in progress, stuck, done "#
                + #"and needing a decision, with a short version in your briefing.","scope":"personal","#
                + #""trigger_text":"Mondays 09:00","permissions":["reads Jira"],"outputs":["report"],"#
                + #""params":[{"key":"PROJECT","label":"Jira project key","example":"PAY"}],"#
                + #""notes":["Leave the key empty to report on every active project."]}"#
            let template = try JSONDecoder().decode(AutomationTemplate.self, from: Data(templateJSON.utf8))
            let text = try XCTUnwrap(String(data: try JSONEncoder().encode(stateReport), encoding: .utf8))
            let hash = AutomationDraftColumnModel.contentHash(stateReport)
            let render = #"{"name":"jira-state-report","scope":"personal","params":{},"files":[{"#
                + #""slug":"jira-state-report","text":\#(text),"validate":{"ok":true,"errors":[],"#
                + #""slug":"jira-state-report","name":"Jira state report","scope":"personal","#
                + #""approval_hash":"h1","content_hash":"\#(hash)","permissions":["jira:read","llm:light"],"#
                + #""outputs":["report","briefing"],"widening":[],"#
                + #""fields":{"trigger":"schedule: 0 9 * * 1","missed":"skip","concurrency":"1","#
                + #""budget":{"tokens":60000,"minutes":10}}}}]}"#
            let cli = AutomationsCLI(runner: FakeCLIRunner(stdout: Data(render.utf8)))
            let model = AutomationTemplatePanelModel(template: template, scope: .personal, cli: cli) { _ in }
            Task { await model.appear() }
            let deadline = Date().addingTimeInterval(5)
            while !model.canSave, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertTrue(model.canSave, "the fixture's render did not land: \(model.state)")
            return AnyView(AutomationTemplatePanel(model: model, onAdjustInChat: { _ in }, onDone: { _ in }))
        } catch {
            return failure(error)
        }
    }

    private static func failure(_ error: Error) -> AnyView {
        XCTFail("automation shot fixture failed: \(error)")
        return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
    }
}

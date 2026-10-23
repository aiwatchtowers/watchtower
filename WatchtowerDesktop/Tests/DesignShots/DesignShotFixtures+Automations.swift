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

    /// The draft column on a confirm of "acme digest": one widening (a
    /// `shell:` entry, so the shell warning shows), one change line with
    /// who made it, and a dry run of the same text.
    static func draftColumn() -> AnyView {
        do {
            let changes = #"[{"field":"trigger","old":"{\"schedule\":\"0 8 * * 1-5\"}","#
                + #""new":"{\"schedule\":\"0 9 * * 1-5\"}"}]"#
            let hash = AutomationDraftColumnModel.contentHash(digest)
            let json = #"{"ok":true,"errors":[],"slug":"acme-digest","name":"acme digest","scope":"personal","#
                + #""approval_hash":"h2","content_hash":"\#(hash)","permissions":["gmail:read@work","llm:light","#
                + #""shell:\"make digest\""],"outputs":["inbox"],"widening":["shell:\"make digest\""],"changes":\#(changes),"changes_known":true,"#
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
            let now = Date(timeIntervalSince1970: 1_792_152_000)
            let saved = AutomationDraftColumnModel.Saved(changedBy: "", changedAt: now.addingTimeInterval(-600),
                                                         needsConfirmation: true, llmAutoWrites: [])
            let model = AutomationDraftColumnModel(text: digest, validated: validated, isChecking: false,
                                                   newestChatEntry: newest, confirmedText: confirmed, isNew: false,
                                                   plan: nil, saved: saved, now: now)
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

    /// The six templates in `automations templates --json` order.
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
      "trigger_text":"Button: Release","permissions":["runs a shell command"],"outputs":["report"]},
     {"name":"on-reaction","title":"When I react with an emoji","description":"Runs on a reaction.",
      "scope":"personal","trigger_text":"When you react with :eyes:","permissions":["reads Slack"],
      "outputs":["inbox"]}]
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

    private static var poolPaths: [String] = []

    /// Removes the shots' databases (`DesignShotFixtures.cleanUp`).
    static func cleanUp() {
        poolPaths.forEach(TestDatabase.cleanup(path:))
        poolPaths = []
    }

    /// A fresh test database, removed by `cleanUp`.
    private static func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.createPool()
        poolPaths.append(path)
        return pool
    }

    /// `show --json` for a card: its description, nothing widened or changed.
    private static func showJSON(name: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": 1, "slug": "x", "scope": "personal", "project_id": 0, "path": "/acme/automations/x.md",
            "name": name, "description": "Summarises the morning mail and flags what needs an answer today.",
            "script": "", "recipe_text": digest, "trigger_kind": "schedule",
            "trigger_spec": #"{"schedule":"0 9 * * 1-5"}"#, "permissions": ["gmail:read@work", "llm:light"],
            "outputs": ["inbox", "report"], "budget_tokens": 40000, "budget_minutes": 5, "concurrency": 1,
            "missed_policy": "skip", "pause_timeout_hours": 72, "enabled": true, "runnable": true,
            "needs_confirmation": false, "parse_error": "", "content_hash": "c1", "approval_hash": "h1",
            "confirmed_hash": "h1", "widening": [String](), "grants": [String](), "changes": [String](),
            "changes_known": true, "changed_by": "", "changed_at": NSNull()
        ] as [String: Any])
    }

    private static func hooks(acmeID: Int64?) -> AutomationEditorChatHooks {
        let acme = acmeID.map { AutomationScopeChoice.workbench(id: $0, name: "acme", folder: "/work/acme") }
        return AutomationEditorChatHooks(
            scopes: [.personal] + (acme.map { [$0] } ?? []), workspaceDir: "/acme",
            draftContextID: { _ in "shot" }, makeNewChat: { _, _ in nil }, makeEditChat: { _ in nil },
            templatePanel: { _, _ in nil }, startTemplate: { _, _ in nil }
        )
    }

    /// Two runs (a failed one, then a newer one that succeeded) with their
    /// steps and two reports.
    private static func insertHistory(_ db: Database, automationID: Int64) throws {
        let failed = try TestDatabase.insertAutomationRun(
            db, automationID: automationID, trigger: "schedule", status: "failed", inputTokens: 1200,
            error: "list_emails: the account needs to sign in again",
            queuedAt: "2026-10-19T09:00:00Z", startedAt: "2026-10-19T09:00:01Z", finishedAt: "2026-10-19T09:00:03Z")
        try TestDatabase.insertAutomationStep(db, runID: failed, seq: 1, kind: "tool", name: "list_emails",
                                              status: "error")
        try TestDatabase.insertAutomationOutput(db, automationID: automationID, runID: failed, kind: "report",
                                                title: "Morning mail, Oct 18", body: "Nothing urgent.",
                                                createdAt: "2026-10-18T09:00:12Z")
        let ok = try TestDatabase.insertAutomationRun(
            db, automationID: automationID, trigger: "schedule", inputTokens: 5200, outputTokens: 900,
            queuedAt: "2026-10-20T09:00:00Z", startedAt: "2026-10-20T09:00:01Z", finishedAt: "2026-10-20T09:00:14Z")
        try TestDatabase.insertAutomationStep(db, runID: ok, seq: 1, kind: "tool", name: "list_emails")
        try TestDatabase.insertAutomationStep(db, runID: ok, seq: 2, kind: "llm", name: "light")
        try TestDatabase.insertAutomationOutput(db, automationID: automationID, runID: ok, kind: "report",
                                                title: "Morning mail, Oct 20",
                                                body: "Three threads need an answer today.",
                                                createdAt: "2026-10-20T09:00:14Z")
    }

    /// A New automation chat for workbench `acme` with a draft on disk.
    private static func insertDraft(_ db: Database, databasePath: String, acme: Int64) throws {
        try db.execute(sql: """
            INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
            VALUES ('New automation', 'automation_draft', ?, 0, 0)
            """, arguments: ["shot-wb\(acme)"])
        let url = AutomationDraftEntry.cacheURL(databasePath: databasePath, conversationID: db.lastInsertedRowID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (cacheLine() + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// The tab (spec A1): Personal with an off automation and one that needs
    /// confirmation, acme with a draft row and a paused automation, and the
    /// first automation's card in the panel.
    static func list() -> AnyView {
        do {
            let pool = try makePool()
            let path = pool.path
            let (acmeID, firstID) = try pool.write { db -> (Int64, Int64) in
                let acme = try TestDatabase.insertWorkbench(db, name: "acme", folder: "/work/acme")
                let first = try TestDatabase.insertAutomation(
                    db, slug: "morning-mail", name: "Morning mail digest", triggerKind: "schedule",
                    triggerSpec: #"{"schedule":"0 9 * * 1-5"}"#, enabled: false,
                    permissionsJSON: #"["gmail:read@work","llm:light"]"#, outputsJSON: #"["inbox","report"]"#)
                try insertHistory(db, automationID: first)
                try TestDatabase.insertAutomation(
                    db, slug: "weekly-status", name: "Weekly status report", triggerKind: "schedule",
                    triggerSpec: #"{"schedule":"0 16 * * 5"}"#, approvalHash: "h2", enabled: false)
                let paused = try TestDatabase.insertAutomation(
                    db, slug: "nightly-triage", name: "Nightly test triage", triggerKind: "schedule",
                    triggerSpec: #"{"schedule":"0 2 * * *"}"#, enabled: false, workbenchID: acme)
                try db.execute(sql: "UPDATE automations SET disabled_reason = ? WHERE id = ?",
                               arguments: ["stopped after a runaway script", paused])
                try insertDraft(db, databasePath: path, acme: acme)
                return (acme, first)
            }
            let vm = AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: RoutedCLIRunner(routes: [
                "show": try showJSON(name: "Morning mail digest")
            ])))
            vm.refresh()
            vm.select(firstID)
            return AnyView(AutomationsView(vm: vm, hooks: hooks(acmeID: acmeID)))
        } catch {
            return failure(error)
        }
    }

    /// The card of an enabled personal automation with its reports and history.
    static func card() -> AnyView {
        do {
            let pool = try makePool()
            let id = try pool.write { db -> Int64 in
                let id = try TestDatabase.insertAutomation(
                    db, slug: "morning-mail", name: "Morning mail digest", triggerKind: "schedule",
                    triggerSpec: #"{"schedule":"0 9 * * 1-5"}"#,
                    permissionsJSON: #"["gmail:read@work","llm:light"]"#, outputsJSON: #"["inbox","report"]"#)
                try insertHistory(db, automationID: id)
                return id
            }
            let vm = AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: RoutedCLIRunner(routes: [
                "show": try showJSON(name: "Morning mail digest")
            ])))
            vm.refresh()
            vm.select(id)
            let item = try XCTUnwrap(vm.items.first)
            return AnyView(AutomationCardView(vm: vm, item: item, actions: AutomationsTabActions(), workbenchName: nil,
                                              now: Date()) {})
        } catch {
            return failure(error)
        }
    }

    /// The editor panel on "acme digest" (id 7, personal) with the chat
    /// still opening on the left: `review` is the "Needs your confirmation"
    /// banner's case — the saved bytes unchanged and not confirmed, so the
    /// footer confirms; otherwise an enabled, confirmed recipe whose
    /// schedule moved from 08:00 to 09:00, so the footer saves and confirms.
    static func editorPanel(review: Bool) -> AnyView {
        do {
            let confirmed = digest.replacingOccurrences(of: "0 9 * * 1-5", with: "0 8 * * 1-5")
            let show: [String: Any] = [
                "id": 7, "slug": "acme-digest", "scope": "personal", "project_id": 0,
                "path": "/acme/automations/acme-digest.md", "name": "acme digest",
                "description": "Summarises the morning mail.", "script": "", "recipe_text": review ? digest : confirmed,
                "trigger_kind": "schedule", "trigger_spec": #"{"schedule":"0 8 * * 1-5"}"#,
                "permissions": ["gmail:read@work", "llm:light"], "outputs": ["inbox"], "budget_tokens": 40000,
                "budget_minutes": 5, "concurrency": 1, "missed_policy": "skip", "pause_timeout_hours": 72,
                "enabled": !review, "runnable": !review, "needs_confirmation": review, "parse_error": "",
                "content_hash": "c1", "approval_hash": review ? "h2" : "h1", "confirmed_hash": "h1",
                "widening": [String](), "grants": [String](), "changes": [String](), "changes_known": true,
                "changed_by": "", "changed_at": NSNull()
            ]
            let changes = #"[{"field":"trigger","old":"{\"schedule\":\"0 8 * * 1-5\"}","#
                + #""new":"{\"schedule\":\"0 9 * * 1-5\"}"}]"#
            let validate = #"{"ok":true,"errors":[],"slug":"acme-digest","name":"acme digest","scope":"personal","#
                + #""approval_hash":"h2","content_hash":"\#(AutomationDraftColumnModel.contentHash(digest))","#
                + #""permissions":["gmail:read@work","llm:light"],"outputs":["inbox"],"widening":[],"#
                + #""changes":\#(changes),"changes_known":true,"#
                + #""fields":{"trigger":"schedule: 0 9 * * 1-5","missed":"skip","concurrency":"1","#
                + #""budget":{"tokens":40000,"minutes":5}}}"#
            let runner = RoutedCLIRunner(routes: [
                "show": try JSONSerialization.data(withJSONObject: show), "validate": Data(validate.utf8)
            ])
            let cli = AutomationsCLI(runner: runner)
            let editor = AutomationEditorCenter(cli: cli, grants: { _ in [] }, refresh: { _ in }, sleep: { _ in })
            let pool = try makePool()
            let vm = AutomationsViewModel(dbPool: pool, cli: cli)
            Task {
                await editor.beginEdit(7, chatNewestText: nil)
                if !review { editor.drafts[7]?.buffer.replace(text: digest) }
                editor.textChanged(7)
            }
            let deadline = Date().addingTimeInterval(5)
            while !editor.canSave(7), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertTrue(editor.canSave(7), "the fixture's check did not land: \(String(describing: editor.saving[7]))")
            return AnyView(AutomationEditorPanel(
                target: .existing(7), editor: editor, vm: vm,
                // The chat never opens: its spinner stays on the left.
                makeChat: {
                    try await Task.sleep(for: .seconds(86_400))
                    return nil
                },
                scopeTitle: "Personal", workspaceDir: "/acme", toolsAvailable: true,
                onSaved: { _ in }, onDiscardDraft: nil
            ))
        } catch {
            return failure(error)
        }
    }

    private static func failure(_ error: Error) -> AnyView {
        XCTFail("automation shot fixture failed: \(error)")
        return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
    }
}

/// Answers each `automations <subcommand>` with its fixed JSON.
private final class RoutedCLIRunner: CLIRunnerProtocol, Sendable {
    private let routes: [String: Data]

    init(routes: [String: Data]) {
        self.routes = routes
    }

    func run(args: [String]) async throws -> Data {
        guard args.count > 1, let data = routes[args[1]] else {
            throw CLIRunnerError.nonZeroExit(code: 1, stderr: "no fixture for \(args)")
        }
        return data
    }
}

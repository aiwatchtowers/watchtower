import GRDB
import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The "New automation" Draft panel over the editor's draft cache lines
/// (`internal/automations/authoring/draftcache.go`).
final class AutomationDraftPanelModelTests: XCTestCase {
    private static let recipe = "---\nname: \"Morning mail\"\ntrigger:\n  schedule: \"0 9 * * 1-5\"\nmissed: \"run_once\"\n---\n"

    /// One cache line as Go writes it: every key present.
    private func line(
        name: String = "Morning mail",
        recipe: String = recipe,
        triggerKind: String = "schedule",
        trigger: String = "0 9 * * 1-5",
        permissions: [String] = ["gmail:read@work", "llm:light"],
        outputs: [String] = ["inbox"],
        dryRun: [String: Any]? = [
            "steps": [
                ["seq": 1, "kind": "tool", "name": "list_emails", "status": "ok", "args": "{}", "result": "17",
                 "permission": "gmail:read@work", "error": "", "tokens": 0],
                ["seq": 2, "kind": "llm", "name": "light", "status": "ok", "args": "", "result": "",
                 "permission": "llm:light", "error": "", "tokens": 1050],
                ["seq": 3, "kind": "output", "name": "inbox", "status": "dry_run",
                 "args": #"{"title":"Mail: 4 need a reply"}"#, "result": "", "permission": "", "error": "",
                 "tokens": 0]
            ],
            "outputs": [], "tokens": 1050, "status": "succeeded", "error": ""
        ],
        errors: [String] = []
    ) throws -> String {
        let result: [String: Any] = [
            "ok": errors.isEmpty, "errors": errors, "widening": [],
            "manifest": [
                "name": name, "slug": "", "scope": "personal", "trigger_kind": triggerKind, "trigger": trigger,
                "permissions": permissions, "outputs": outputs, "budget_tokens": 40000, "budget_minutes": 5,
                "approval_hash": "h"
            ],
            "dry_run": dryRun ?? NSNull()
        ]
        let entry: [String: Any] = ["recipe_text": recipe, "result": result, "at": "2026-10-14T12:00:00Z"]
        let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    /// The cache rows of a newline-joined list of entries (blank lines dropped).
    private func entries(_ cache: String) -> [String] {
        cache.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func model(_ cache: String) -> AutomationDraftPanelModel {
        AutomationDraftPanelModel(newest: AutomationDraftEntry.newest(in: entries(cache)))
    }

    func testPanelFromLatestDraftResult() throws {
        let older = try line(name: "Old draft")
        let newer = try line(name: "Morning mail", recipe: Self.recipe + "newer\n")
        let panel = model(older + "\n" + newer + "\n")
        XCTAssertFalse(panel.isEmpty)
        XCTAssertEqual(panel.name, "Morning mail")
        XCTAssertEqual(panel.recipeText, Self.recipe + "newer\n", "Show recipe shows the newest entry's text")
        XCTAssertEqual(panel.dryRunLines, ["Read list_emails", "Asked the assistant · 1,050 tokens",
                                           "Would post to Inbox: Mail: 4 need a reply"])
        XCTAssertNil(panel.dryRunNote)
    }

    func testRefusedDryRunShowsReason() throws {
        let message = "This recipe is not confirmed yet; only you can dry-run it, from its card in Automations"
        let panel = model(try line(dryRun: [
            "steps": [], "outputs": [], "tokens": 0, "status": "refused", "error": message
        ]))
        XCTAssertEqual(panel.dryRunNote, message)
        XCTAssertEqual(panel.dryRunLines, [])
    }

    /// A draft that reached mcp() stops there (ask #326): the steps before it
    /// show, and the note points to the card's Dry run — not a failure.
    func testStoppedDryRunShowsStepsAndCardHint() throws {
        let message = "Stopped at mcp(): external calls are not made in a draft; "
            + "dry-run the saved recipe from its card to see the rest"
        let panel = model(try line(dryRun: [
            "steps": [
                ["seq": 1, "kind": "tool", "name": "list_targets", "status": "ok", "args": "{}", "result": "[]",
                 "permission": "", "error": "", "tokens": 0],
                ["seq": 2, "kind": "mcp", "name": "github/list_prs", "status": "dry_run", "args": "{}",
                 "result": "", "permission": "mcp:github/*", "error": "", "tokens": 0]
            ],
            "outputs": [], "tokens": 0, "status": "stopped", "error": message
        ]))
        XCTAssertEqual(panel.dryRunLines, [
            "Read list_targets",
            "Stopped before calling github/list_prs: Quick Connections are not called in a draft"
        ])
        XCTAssertEqual(panel.dryRunNote, message)
    }

    func testParseErrorShowsErrors() throws {
        let panel = model(try line(name: "", dryRun: nil, errors: ["line 2: name is required"]))
        XCTAssertEqual(panel.errors, ["line 2: name is required"])
        XCTAssertEqual(panel.dryRunLines, [])
    }

    func testNoDraftYetEmptyState() throws {
        XCTAssertTrue(model("").isEmpty)
        XCTAssertTrue(model("\n  \n").isEmpty)
        XCTAssertNil(model("").shownRecipeText)
        let db = try TestDatabase.create()
        XCTAssertEqual(AutomationDraftPanelModel.load(db, conversationID: 9), .empty)
    }

    /// A newest line that does not decode is the third state: the panel says
    /// it could not read the draft, never shows the older line as current.
    func testUndecodableNewestLineIsUnreadableNotTheOlderDraft() throws {
        let panel = model(try line(name: "Old draft") + "\n{\"recipe_text\": 42}\n")
        XCTAssertTrue(panel.isUnreadable)
        XCTAssertFalse(panel.isEmpty)
        XCTAssertNotEqual(panel.name, "Old draft")
        XCTAssertNil(panel.shownRecipeText)
        XCTAssertTrue(model("not json\n").isUnreadable)
    }

    /// A draft whose evaluation failed (Go caches `result: null` + `error`)
    /// is the newest draft, shown with its error — not the one before it.
    func testEvaluationErrorEntryShowsItsError() throws {
        let failing: [String: Any] = ["recipe_text": "---\nname: Broken\n---\n", "result": NSNull(),
                                      "error": "workbench_id must be a workbench id", "at": "2026-10-14T12:01:00Z"]
        let data = try JSONSerialization.data(withJSONObject: failing, options: [.sortedKeys])
        let failingLine = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        let panel = model(try line(name: "Old draft") + "\n" + failingLine + "\n")
        XCTAssertFalse(panel.isEmpty)
        XCTAssertFalse(panel.isUnreadable)
        XCTAssertEqual(panel.recipeText, "---\nname: Broken\n---\n")
        XCTAssertEqual(panel.shownRecipeText, "---\nname: Broken\n---\n")
        XCTAssertEqual(panel.errors, ["Couldn't check this draft: workbench_id must be a workbench id"])
        XCTAssertEqual(panel.dryRunLines, [])
    }

    /// A cache that cannot be read is unreadable, not "no draft yet".
    func testUnreadableCacheIsUnreadable() throws {
        let db = try TestDatabase.create()
        try db.write { try $0.execute(sql: "DROP TABLE automation_draft_cache") }
        XCTAssertEqual(AutomationDraftPanelModel.load(db, conversationID: 5), .unreadable)
    }

    /// The panel shows the conversation's newest cache row (#604 G2: the
    /// cache moved from `automation-drafts/<id>.jsonl` into the database).
    func testPanelShowsNewestRowEntry() throws {
        let db = try TestDatabase.create()
        let conversation = try insertConversation(db)
        try db.write { db in
            try AutomationDraftCacheQueries.append(db, conversationID: conversation, entryJSON: try line(name: "Old"),
                                                   at: Date(timeIntervalSince1970: 1))
            try AutomationDraftCacheQueries.append(db, conversationID: conversation,
                                                   entryJSON: try line(name: "Morning mail"),
                                                   at: Date(timeIntervalSince1970: 2))
        }
        XCTAssertEqual(AutomationDraftPanelModel.load(db, conversationID: conversation).name, "Morning mail")
    }

    /// A saved or discarded draft's rows go, and only that conversation's.
    func testDiscardDeletesRows() throws {
        let db = try TestDatabase.create()
        let gone = try insertConversation(db)
        let kept = try insertConversation(db)
        try db.write { db in
            for id in [gone, kept] {
                try AutomationDraftCacheQueries.append(db, conversationID: id, entryJSON: try line(), at: Date())
            }
            try AutomationDraftCacheQueries.delete(db, conversationID: gone)
        }
        XCTAssertEqual(AutomationDraftPanelModel.load(db, conversationID: gone), .empty)
        XCTAssertEqual(AutomationDraftPanelModel.load(db, conversationID: kept).name, "Morning mail")
    }

    private func insertConversation(_ db: DatabaseQueue) throws -> Int64 {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
                VALUES ('New automation', 'automation_draft', 'd', 0, 0)
                """)
            return db.lastInsertedRowID
        }
    }

    // MARK: - Sessions it starts

    private func sessionDryRun(_ prompt: String) -> [String: Any] {
        [
            "steps": [
                ["seq": 1, "kind": "session", "name": "claude", "status": "dry_run",
                 "args": #"{"agent":"claude","prompt":"\#(prompt)","title":"Release"}"#, "result": "",
                 "permission": "session:start", "error": "", "tokens": 0]
            ],
            "outputs": [], "tokens": 0, "status": "succeeded", "error": ""
        ]
    }

    /// The panel shows the newest draft's sessions; the save card looks up
    /// the newest cached draft with its exact text, among the last five.
    func testSessionsAndDryRunSessionsByText() throws {
        let older = try line(recipe: "A", dryRun: sessionDryRun("Run /release"))
        let noDryRun = try line(recipe: "B", dryRun: nil)
        let newer = try line(recipe: "C", dryRun: sessionDryRun("Run /deploy"))
        let cache = [older, noDryRun, newer].joined(separator: "\n") + "\n"
        let panel = model(cache)
        XCTAssertEqual(panel.sessions, [AutomationSessionPrompt(kind: "session", title: "Release", prompt: "Run /deploy")])
        let byText = AutomationDraftPanelModel.dryRunSessions(in: entries(cache))
        XCTAssertEqual(byText["A"], AutomationDryRunSessions(
            sessions: [AutomationSessionPrompt(kind: "session", title: "Release", prompt: "Run /release")],
            stoppedEarly: false))
        XCTAssertNil(byText["B"], "a draft without a dry run shows no sessions")
        XCTAssertEqual(byText["C"]?.sessions.first?.prompt, "Run /deploy")
        XCTAssertEqual(model("").sessions, [])
    }

    /// A dry run that ended before the script did (the mcp() draft stop,
    /// ask #326, or an error) may have more sessions after it.
    func testDryRunSessionsStoppedEarly() throws {
        var stopped = sessionDryRun("Run /release")
        stopped["status"] = "stopped"
        stopped["error"] = "the draft stops at mcp()"
        var failed = sessionDryRun("Run /release")
        failed["status"] = "failed"
        let cache = [try line(recipe: "A", dryRun: stopped), try line(recipe: "B", dryRun: failed),
                     try line(recipe: "C", dryRun: sessionDryRun("Run /release"))].joined(separator: "\n")
        let byText = AutomationDraftPanelModel.dryRunSessions(in: entries(cache))
        XCTAssertEqual(byText["A"]?.stoppedEarly, true)
        XCTAssertEqual(byText["A"]?.sessions.count, 1, "the sessions before the stop still show")
        XCTAssertEqual(byText["B"]?.stoppedEarly, true)
        XCTAssertEqual(byText["C"]?.stoppedEarly, false)
    }
}

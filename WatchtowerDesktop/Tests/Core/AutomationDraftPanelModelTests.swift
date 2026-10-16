import XCTest
@testable import WatchtowerCore

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

    private func model(_ cache: String) -> AutomationDraftPanelModel {
        AutomationDraftPanelModel(entry: AutomationDraftEntry.newest(inCache: cache))
    }

    func testPanelFromLatestDraftResult() throws {
        let older = try line(name: "Old draft")
        let newer = try line(name: "Morning mail", recipe: Self.recipe + "newer\n")
        let panel = model(older + "\n" + newer + "\n")
        XCTAssertFalse(panel.isEmpty)
        XCTAssertEqual(panel.name, "Morning mail")
        XCTAssertEqual(panel.recipeText, Self.recipe + "newer\n", "Show recipe shows the newest entry's text")
        XCTAssertEqual(panel.when, "Every weekday at 09:00")
        XCTAssertEqual(panel.whenDetail, "Your local time · if the Mac was asleep, runs once when it wakes")
        XCTAssertEqual(panel.budget, "40,000 tokens · 5 min")
        XCTAssertEqual(panel.lastDryRunTokens, "Last dry run used 1,050 tokens")
        XCTAssertEqual(panel.permissions.map(\.manifest), ["gmail:read@work", "llm:light", "output: inbox"])
        XCTAssertEqual(panel.permissions.first?.plain, "Read mail in work (Gmail)")
        XCTAssertEqual(panel.dryRunLines, ["Read list_emails", "Asked the assistant · 1,050 tokens",
                                           "Would post to Inbox: Mail: 4 need a reply"])
        XCTAssertNil(panel.dryRunNote)
    }

    func testMissedSkipInWords() throws {
        let skip = Self.recipe.replacingOccurrences(of: "run_once", with: "skip")
        XCTAssertEqual(model(try line(recipe: skip)).whenDetail,
                       "Your local time · if the Mac was asleep, skips that time")
        XCTAssertNil(model(try line(triggerKind: "manual", trigger: "manual")).whenDetail)
    }

    func testCantLineListsUndeclaredWrites() throws {
        XCTAssertEqual(model(try line()).cantLine, "It can't send mail, post to Slack or change Jira.")
        XCTAssertEqual(AutomationDraftPanelModel.cantLine(permissions: ["gmail:write@work"], outputs: ["slack"]),
                       "It can't change Jira.")
        XCTAssertNil(AutomationDraftPanelModel.cantLine(
            permissions: ["gmail:write@work", "slack:write@acme", "jira:write@ACME"], outputs: []))
    }

    func testRefusedDryRunShowsReason() throws {
        let message = "This recipe is not confirmed yet; only you can dry-run it, from its card in Automations"
        let panel = model(try line(dryRun: [
            "steps": [], "outputs": [], "tokens": 0, "status": "refused", "error": message
        ]))
        XCTAssertEqual(panel.dryRunNote, message)
        XCTAssertEqual(panel.dryRunLines, [])
        XCTAssertNil(panel.lastDryRunTokens)
    }

    func testParseErrorShowsErrors() throws {
        let panel = model(try line(name: "", dryRun: nil, errors: ["line 2: name is required"]))
        XCTAssertEqual(panel.errors, ["line 2: name is required"])
        XCTAssertNil(panel.cantLine)
        XCTAssertEqual(panel.dryRunLines, [])
    }

    func testNoDraftYetEmptyState() throws {
        XCTAssertTrue(model("").isEmpty)
        XCTAssertTrue(model("not json\n").isEmpty)
        let missing = AutomationDraftPanelModel.load(databasePath: "/nonexistent-acme/watchtower.db", conversationID: 9)
        XCTAssertEqual(missing, .empty)
    }

    func testLoadReadsTheConversationCacheBesideTheDatabase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("draft-panel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("watchtower.db").path
        let url = AutomationDraftEntry.cacheURL(databasePath: dbPath, conversationID: 42)
        XCTAssertEqual(url.path, dir.appendingPathComponent("automation-drafts/42.jsonl").path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (try line() + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(AutomationDraftPanelModel.load(databasePath: dbPath, conversationID: 42).name, "Morning mail")
    }
}

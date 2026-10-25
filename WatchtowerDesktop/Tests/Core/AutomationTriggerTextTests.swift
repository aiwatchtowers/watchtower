import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class AutomationTriggerTextTests: XCTestCase {
    func testDescribe() {
        let cases: [(kind: String, spec: String, want: String)] = [
            ("schedule", #"{"schedule":"0 9 * * 1-5"}"#, "Weekdays 09:00"),
            ("schedule", #"{"schedule":"0 9 * * *"}"#, "Daily 09:00"),
            ("schedule", #"{"schedule":"0 10,16 * * 1-5"}"#, "Weekdays 10:00, 16:00"),
            ("schedule", #"{"schedule":"0 9 * * 1"}"#, "Mondays 09:00"),
            ("schedule", #"{"schedule":"0 17 * * 5"}"#, "Fridays 17:00"),
            ("schedule", #"{"schedule":"30 7 * * 0"}"#, "Sundays 07:30"),
            ("schedule", #"{"schedule":"*/15 * * * *"}"#, "Cron: */15 * * * *"),
            ("schedule", #"{"schedule":"0 9 1 * *"}"#, "Cron: 0 9 1 * *"),
            ("button", #"{"button":{"label":"Release","confirm":false}}"#, "Button: Release"),
            ("event", #"{"event":{"type":"gmail.new_messages","where":{"account":"work"}}}"#, "On new Gmail (work)"),
            ("event", #"{"event":{"type":"gmail.new_messages"}}"#, "On new Gmail"),
            ("event", #"{"event":{"type":"slack.new_messages"}}"#, "On new Slack messages"),
            ("event", #"{"event":{"type":"jira.issue_changed"}}"#, "On Jira change"),
            ("event", #"{"event":{"type":"calendar.event_changed"}}"#, "On calendar change"),
            ("event", #"{"event":{"type":"confluence.page_changed"}}"#, "On Confluence change"),
            ("event", #"{"event":{"type":"slack.reaction_added"}}"#, "On a Slack reaction"),
            ("event", #"{"event":{"type":"slack.reaction_added","where":{"emoji":"eyes"}}}"#, "On :eyes: reactions"),
            ("event", #"{"event":{"type":"slack.reaction_added","where":{"emoji":":eyes:"}}}"#, "On :eyes: reactions"),
            ("manual", #"{"manual":true}"#, "Manual"),
            ("", "{}", "—")
        ]
        for c in cases {
            XCTAssertEqual(AutomationTriggerText.describe(kind: c.kind, specJSON: c.spec), c.want, "\(c.kind) \(c.spec)")
        }
    }

    // MARK: - Built-ins

    /// Twin of Go `db.TriggerSync`: a built-in's run at its slot in the sync cycle.
    func testSyncTriggerDecodesAndLabels() throws {
        let queue = try TestDatabase.create()
        let (automation, run) = try queue.write { db in
            try db.execute(sql: """
                INSERT INTO automations (slug, scope, path, name, trigger_kind, trigger_spec, origin, builtin_id,
                    overridden, builtin_base_hash)
                VALUES ('morning-brief', 'personal', 'builtin:morning-brief', 'Morning brief', 'sync',
                    '{"sync":"morning_brief"}', 'builtin', 'morning-brief', 1, 'base')
                """)
            let id = db.lastInsertedRowID
            try TestDatabase.insertAutomationRun(db, automationID: id, trigger: "sync")
            return (try XCTUnwrap(Automation.fetchOne(db, sql: "SELECT * FROM automations WHERE id = ?",
                                                      arguments: [id])),
                    try XCTUnwrap(AutomationRun.fetchOne(db, sql: "SELECT * FROM automation_runs")))
        }
        XCTAssertTrue(automation.isBuiltin)
        XCTAssertEqual(automation.origin, .builtin)
        XCTAssertEqual(automation.builtinID, "morning-brief")
        XCTAssertTrue(automation.overridden)
        XCTAssertEqual(automation.builtinBaseHash, "base")
        XCTAssertEqual(run.trigger, "sync")
        XCTAssertEqual(AutomationCardPresentation.triggerLabel(run), "At its slot in the sync cycle")
        let words = "Every morning, at the first sync after its time"
        XCTAssertEqual(AutomationTriggerText.describe(kind: "sync", specJSON: #"{"sync":"morning_brief"}"#), words)
        XCTAssertEqual(AutomationTriggerText.sentence(kind: "sync", specJSON: #"{"sync":"morning_brief"}"#), words)
    }

    func testOwnerRowDecodesAsOwner() throws {
        let queue = try TestDatabase.create()
        let automation = try queue.write { db in
            let id = try TestDatabase.insertAutomation(db)
            return try XCTUnwrap(Automation.fetchOne(db, sql: "SELECT * FROM automations WHERE id = ?",
                                                     arguments: [id]))
        }
        XCTAssertFalse(automation.isBuiltin)
        XCTAssertNil(automation.builtinID)
        XCTAssertFalse(automation.overridden)
        XCTAssertEqual(automation.builtinBaseHash, "")
    }

    func testSyncIsABackgroundTrigger() {
        XCTAssertTrue(AutomationFailureWatch.backgroundTriggers.contains("sync"))
    }

    /// Twin of Go `automations.BuiltinPrimitiveNames`.
    func testBuiltinPermissionLines() {
        XCTAssertEqual(AutomationCardPresentation.permissionLine("builtin:brief.compose"), "Write your daily brief")
        XCTAssertEqual(AutomationCardPresentation.permissionLine("builtin:plan.compose"), "Plan your day")
        XCTAssertEqual(AutomationCardPresentation.permissionLine("builtin:x.y"), "builtin:x.y", "unknown stays as written")
    }

    /// Each sync slot in words (twin: Go `builtin` slot names).
    func testSyncSlotTexts() {
        let words = [
            "tracks": "After every sync",
            "ideas": "Every few hours",
            "reactions": "When you react in Slack",
            "custom_tracks": "After every sync"
        ]
        for (slot, text) in words {
            let spec = #"{"sync":"\#(slot)"}"#
            XCTAssertEqual(AutomationTriggerText.describe(kind: "sync", specJSON: spec), text, slot)
            XCTAssertEqual(AutomationTriggerText.sentence(kind: "sync", specJSON: spec), text, slot)
        }
    }

    /// Twin of Go `automations.BuiltinPrimitiveNames` and `CapabilityForPrimitive`.
    func testC3PermissionLines() {
        XCTAssertEqual(AutomationCardPresentation.permissionLine("builtin:tracks.extract"),
                       "Update your tracks from Slack digests")
        XCTAssertEqual(AutomationCardPresentation.permissionLine("builtin:ideas.consolidate"),
                       "Find ideas and decisions in your messages")
        XCTAssertEqual(AutomationCardPresentation.permissionLine("builtin:reaction.compose"),
                       "Turn your reactions into proposals")
        XCTAssertEqual(AutomationCardPresentation.permissionLine("track:scan"), "Add events to this watch's track")
    }
}

import XCTest
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
            ("manual", #"{"manual":true}"#, "Manual"),
            ("", "{}", "—")
        ]
        for c in cases {
            XCTAssertEqual(AutomationTriggerText.describe(kind: c.kind, specJSON: c.spec), c.want, "\(c.kind) \(c.spec)")
        }
    }
}

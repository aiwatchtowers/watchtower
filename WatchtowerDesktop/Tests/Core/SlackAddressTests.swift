@testable import WatchtowerCore
import XCTest

/// Company code from the Slack app spec, "Desktop — No code?": the Slack
/// address a colleague types to open the workspace's app list.
final class SlackAddressTests: XCTestCase {
    func testWorkspaceForms() {
        let accepted = [
            "acme",
            "acme.slack.com",
            "ACME.Slack.com",
            "  acme.slack.com  ",
            "https://acme.slack.com",
            "https://acme.slack.com/",
            "https://acme.slack.com/marketplace/A0X-watchtower",
            "http://acme.slack.com/apps"
        ]
        for input in accepted {
            XCTAssertEqual(SlackAddress.parse(input), .workspace("acme"), input)
        }
        XCTAssertEqual(SlackAddress.parse("acme-eu"), .workspace("acme-eu"))
    }

    func testEmpty() {
        XCTAssertEqual(SlackAddress.parse(""), .empty)
        XCTAssertEqual(SlackAddress.parse("   "), .empty)
    }

    func testOrganization() {
        XCTAssertEqual(SlackAddress.parse("acme.enterprise.slack.com"), .organization)
        XCTAssertEqual(SlackAddress.parse("https://acme.enterprise.slack.com/"), .organization)
    }

    func testInvalid() {
        let refused = [
            "slack.com",
            "app.slack.com",
            "acme.example.com",
            "ac me",
            "ac_me",
            "acmé",
            "a.b.slack.com",
            "https://"
        ]
        for input in refused {
            XCTAssertEqual(SlackAddress.parse(input), .invalid, input)
        }
    }

    func testAppsURL() {
        XCTAssertEqual(SlackAddress.appsURL(workspace: "acme").absoluteString, "https://acme.slack.com/apps/manage")
    }
}

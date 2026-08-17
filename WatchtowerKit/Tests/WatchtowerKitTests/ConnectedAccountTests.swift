import XCTest
import GRDB
@testable import WatchtowerKit

/// Wire-format freeze for the connected-account slices: each literal payload
/// below is byte-for-byte what SlicePublisher publishes for its kind (the
/// projection column set is pinned on the desktop side by
/// SlicePublisherTests). If `ConnectedAccount` stops decoding one of these,
/// phones in the field stop rendering accounts — change the model, not the
/// fixtures.
final class ConnectedAccountTests: XCTestCase {

    private func decode(_ literal: String) throws -> ConnectedAccount {
        try ConnectedAccount(row: RowPayloadCoder.row(from: Data(literal.utf8)))
    }

    func testSlackAccountLiteralPayloadDecodes() throws {
        let account = try decode(
            #"{"enabled":1,"error":"","id":1,"label":"Work","status":"ok","team_domain":"acme","team_name":"Acme Corp"}"#
        )
        XCTAssertEqual(account.id, 1)
        XCTAssertEqual(account.teamName, "Acme Corp")
        XCTAssertEqual(account.teamDomain, "acme")
        XCTAssertEqual(account.label, "Work")
        XCTAssertTrue(account.isOK)
        XCTAssertFalse(account.isRevoked)
        XCTAssertTrue(account.enabled)
        XCTAssertEqual(account.displayName, "Work")
        XCTAssertEqual(account.detail, "acme.slack.com")
        // Slack payloads carry no Google grant columns — defaults apply.
        XCTAssertFalse(account.calendarEnabled)
        XCTAssertFalse(account.gmailEnabled)
    }

    func testGoogleAccountLiteralPayloadDecodes() throws {
        let account = try decode(
            #"{"calendar_enabled":1,"email":"me@example.com","error":"token expired","gmail_enabled":0,"id":2,"label":"","status":"error"}"#
        )
        XCTAssertEqual(account.id, 2)
        XCTAssertEqual(account.email, "me@example.com")
        XCTAssertFalse(account.isOK)
        XCTAssertFalse(account.isRevoked)
        XCTAssertEqual(account.error, "token expired")
        XCTAssertTrue(account.calendarEnabled)
        XCTAssertFalse(account.gmailEnabled)
        // No `enabled` column on the wire for Google → participates (true).
        XCTAssertTrue(account.enabled)
        XCTAssertEqual(account.displayName, "me@example.com")
        // The identity IS the primary line — no redundant detail.
        XCTAssertNil(account.detail)
    }

    func testJiraAccountLiteralPayloadDecodes() throws {
        let account = try decode(
            #"{"enabled":0,"error":"","id":3,"label":"","site_name":"Acme Jira","site_url":"https://acme.atlassian.net","status":"revoked"}"#
        )
        XCTAssertEqual(account.id, 3)
        XCTAssertEqual(account.siteName, "Acme Jira")
        XCTAssertEqual(account.siteURL, "https://acme.atlassian.net")
        XCTAssertTrue(account.isRevoked)
        XCTAssertFalse(account.enabled)
        XCTAssertEqual(account.displayName, "Acme Jira")
        XCTAssertEqual(account.detail, "https://acme.atlassian.net")
    }

    /// Valid-but-degenerate row: a not-yet-consented account (OAuth never
    /// completed) has every identity column empty — the positional fallback
    /// keeps the row renderable instead of blank.
    func testEmptyIdentityFallsBackToPositionalName() throws {
        let account = try decode(
            #"{"enabled":1,"error":"","id":7,"label":"","status":"ok","team_domain":"","team_name":""}"#
        )
        XCTAssertEqual(account.displayName, "Account #7")
        XCTAssertNil(account.detail)
    }

    func testAccountSliceKindRecordNames() {
        XCTAssertEqual(SliceKind.slackAccount.recordName(id: "1"), "slack_account-1")
        XCTAssertEqual(SliceKind.googleAccount.recordName(id: "2"), "google_account-2")
        XCTAssertEqual(SliceKind.jiraAccount.recordName(id: "3"), "jira_account-3")
    }
}

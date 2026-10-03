import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The sidebar's two-axis rule (feature AND source) and the account-table
/// read behind its source axis.
final class SidebarVisibilityTests: XCTestCase {
    private func visible(
        features: [String]?, sources: [SidebarSource]?, disabled: Set<String> = [], connected: ConnectedSources
    ) -> Bool {
        SidebarVisibility.isVisible(
            requiredFeatures: features, requiredSources: sources, disabledFeatures: disabled, connected: connected
        )
    }

    // MARK: - Rule

    func testUngatedIsAlwaysVisible() {
        XCTAssertTrue(visible(features: nil, sources: nil, disabled: ["x"], connected: .none))
    }

    func testFeatureTimesSourceMatrix() {
        let cases: [(disabled: Set<String>, connected: ConnectedSources, expected: Bool)] = [
            ([], ConnectedSources(slack: true), true),
            (["f"], ConnectedSources(slack: true), false),
            ([], .none, false),
            (["f"], .none, false)
        ]
        for c in cases {
            XCTAssertEqual(
                visible(features: ["f"], sources: [.messages], disabled: c.disabled, connected: c.connected),
                c.expected, "disabled \(c.disabled), \(c.connected)"
            )
        }
    }

    func testAnyOfOnEachAxis() {
        XCTAssertTrue(visible(features: ["a", "b"], sources: nil, disabled: ["a"], connected: .none))
        XCTAssertFalse(visible(features: ["a", "b"], sources: nil, disabled: ["a", "b"], connected: .none))
        XCTAssertTrue(visible(features: nil, sources: [.calendar, .jira], connected: ConnectedSources(jira: true)))
    }

    func testMessagesMeansSlackOrMail() {
        XCTAssertTrue(ConnectedSources(slack: true).provides(.messages))
        XCTAssertTrue(ConnectedSources(mail: true).provides(.messages))
        XCTAssertFalse(ConnectedSources(calendar: true, jira: true).provides(.messages))
    }

    // MARK: - Reading the account tables

    private func fetch(_ seed: (Database) throws -> Void) throws -> ConnectedSources {
        let queue = try TestDatabase.create()
        try queue.write(seed)
        return try queue.read { db in try ConnectedSources.fetch(db) }
    }

    func testNoAccountsIsNone() throws {
        XCTAssertEqual(try fetch { _ in }, .none)
    }

    func testSlackAndJiraIgnoreRemovedAccounts() throws {
        let removed = try fetch { db in
            _ = try TestDatabase.insertSlackAccount(db, teamID: "T1", status: "removed")
            _ = try TestDatabase.insertJiraAccount(db, cloudID: "c1", status: "removed")
        }
        XCTAssertEqual(removed, .none)

        let live = try fetch { db in
            _ = try TestDatabase.insertSlackAccount(db, teamID: "T1", status: "error")
            _ = try TestDatabase.insertJiraAccount(db, cloudID: "c1")
        }
        XCTAssertEqual(live, ConnectedSources(slack: true, jira: true))
    }

    func testGoogleCountsPerService() throws {
        XCTAssertEqual(
            try fetch { db in _ = try TestDatabase.insertGoogleAccount(db, email: "a@example.com", calendarEnabled: true) },
            ConnectedSources(calendar: true)
        )
        XCTAssertEqual(
            try fetch { db in _ = try TestDatabase.insertGoogleAccount(db, email: "a@example.com", gmailEnabled: true) },
            ConnectedSources(mail: true)
        )
        XCTAssertEqual(try fetch { db in _ = try TestDatabase.insertGoogleAccount(db, email: "a@example.com") }, .none)
    }

    func testImapAndCalDAVCount() throws {
        let sources = try fetch { db in
            _ = try TestDatabase.insertEmailAccount(db)
            _ = try TestDatabase.insertCalendarAccount(db)
        }
        XCTAssertEqual(sources, ConnectedSources(mail: true, calendar: true))
    }
}

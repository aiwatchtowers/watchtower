import XCTest
import SwiftUI
import ViewInspector
import WatchtowerCore
@testable import WatchtowerDesktop

/// Home's purge banner, the connection line and the Privacy switch (board #601).
@MainActor
final class AccountPurgeViewTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0) ?? .current
    private let due = PlanUsageDates.parse("2026-10-24T09:00:00Z")

    private func home(purges: [AccountPurge], onReconnect: @escaping (String) -> Void = { _ in }) -> HomeContent {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return HomeContent(
            snapshot: nil, today: Date(), calendar: calendar, onLink: { _ in }, onHideGettingReady: {},
            onReconnect: onReconnect, purges: purges)
    }

    func testHomeContentShowsTheBannerWithReconnect() throws {
        var reconnected: [String] = []
        let row = AccountPurge(id: 1, source: "jira", accountID: 2, accountLabel: "acme.example.com", dueAt: due)
        let view = home(purges: [row]) { reconnected.append($0) }
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(
            text: "Access to acme.example.com was revoked. Its data will be deleted on October 24 at 09:00 unless you reconnect."))
        try inspected.find(button: "Reconnect").tap()
        XCTAssertEqual(reconnected, ["jira"])
    }

    func testHomeContentWithoutPurgesHasNoBanner() throws {
        let inspected = try home(purges: []).inspect()
        XCTAssertThrowsError(try inspected.find(AccountPurgeBanner.self))
        XCTAssertThrowsError(try inspected.find(button: "Reconnect"))
    }

    /// A running purge cannot be stopped: its line has no Reconnect.
    func testRunningPurgeHasNoReconnect() throws {
        let row = AccountPurge(id: 1, source: "slack", accountID: 1, accountLabel: "Acme", state: "running")
        let inspected = try home(purges: [row]).inspect()
        XCTAssertNoThrow(try inspected.find(text: "Watchtower is deleting Acme's data."))
        XCTAssertThrowsError(try inspected.find(button: "Reconnect"))
    }

    /// A purged account's line in its connection detail points to Re-login.
    func testPurgedAccountLine() throws {
        let line = try XCTUnwrap(AccountPurgeLine.make(center: nil, source: "linear", accountID: 1, isPurged: true))
        XCTAssertTrue(line.deleted)
        XCTAssertNoThrow(try line.inspect().find(text: "This account's synced data was deleted. Re-login to sync it again."))
        XCTAssertNil(AccountPurgeLine.make(center: nil, source: "linear", accountID: 1, isPurged: false))
    }

    func testPrivacySwitchSetByPolicyIsDisabled() throws {
        let policy = PrivacySettingsContent(
            isOn: .constant(true), status: AccountPurgeStatus(enabled: true, enabledBy: "policy"), statusError: nil)
        let inspected = try policy.inspect()
        XCTAssertNoThrow(try inspected.find(text: "Set by your organisation"))
        XCTAssertTrue(try inspected.find(ViewType.Toggle.self).isDisabled())

        let owner = PrivacySettingsContent(
            isOn: .constant(false), status: AccountPurgeStatus(enabled: false, enabledBy: "default"), statusError: nil)
        XCTAssertFalse(try owner.inspect().find(ViewType.Toggle.self).isDisabled())
        XCTAssertThrowsError(try owner.inspect().find(text: "Set by your organisation"))
    }

    func testFootnoteUsesGoNumbers() {
        let text = PrivacySettingsContent.footnote(AccountPurgeStatus(enabled: true, enabledBy: "build", graceHours: 48, leaseDays: 14))
        XCTAssertTrue(text.contains("for 14 days"))
        XCTAssertTrue(text.contains("48 hours later"))
        XCTAssertTrue(text.contains("meeting transcripts are kept"))
    }
}

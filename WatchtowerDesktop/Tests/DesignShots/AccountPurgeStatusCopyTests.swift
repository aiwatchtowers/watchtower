import XCTest
@testable import WatchtowerCore

/// The purge copy of the Slack policy hygiene spec (#1769) equals the
/// mockups' string table, `SlackPolicyMockCopy` (it lives in this test
/// target, so the comparison does too; WatchtowerCore pins its own strings).
final class AccountPurgeStatusCopyTests: XCTestCase {
    private typealias Copy = SlackPolicyMockCopy
    private let utc = TimeZone(secondsFromGMT: 0) ?? .current

    func testCopyMatchesMockups() {
        let byDefault = AccountPurgeStatus(enabled: true, enabledBy: "default")
        let bySetting = AccountPurgeStatus(enabled: true, enabledBy: "setting")
        let off = AccountPurgeStatus(enabled: false, enabledBy: "setting")

        XCTAssertEqual(AccountPurgeStatus.switchTitle, Copy.purgeTitle)
        XCTAssertEqual(AccountPurgeStatus.footnote(byDefault, shown: true), Copy.footDefault)
        XCTAssertEqual(AccountPurgeStatus.footnote(nil, shown: true), Copy.footDefault)
        XCTAssertEqual(AccountPurgeStatus.footnote(bySetting, shown: true), Copy.footOnAll)
        XCTAssertEqual(AccountPurgeStatus.footnote(AccountPurgeStatus(enabled: true, enabledBy: "policy"), shown: true),
                       Copy.footOnAll)
        XCTAssertEqual(AccountPurgeStatus.footnote(off, shown: false), Copy.footOff)

        XCTAssertEqual(AccountPurgeStatus.caption(byDefault, shown: true), Copy.captionDefault)
        XCTAssertEqual(AccountPurgeStatus.caption(nil, shown: true), Copy.captionDefault)
        XCTAssertNil(AccountPurgeStatus.caption(bySetting, shown: true))
        XCTAssertNil(AccountPurgeStatus.caption(byDefault, shown: false))

        XCTAssertEqual(AccountPurgeStatus.removeDialogMessage(slackAccount: "acme", status: byDefault), Copy.removeBodyOn)
        XCTAssertEqual(AccountPurgeStatus.removeDialogMessage(slackAccount: "acme", status: nil), Copy.removeBodyOn)
        XCTAssertEqual(AccountPurgeStatus.removeDialogMessage(slackAccount: "acme", status: off), Copy.removeBodyOff)
        XCTAssertEqual(AccountPurgeStatus.removeButton, Copy.remove)
    }

    func testZeroLeaseRemovedLineMatchesMockup() {
        let row = AccountPurge(id: 1, source: "slack", accountID: 2, accountLabel: "acme", accountStatus: "removed",
                               accessOkAt: PlanUsageDates.parse("2026-11-17T13:00:00Z"), reason: "lease",
                               dueAt: PlanUsageDates.parse("2026-11-20T14:00:00Z"))
        XCTAssertEqual(AccountPurgeNoticePolicy.line(row, zone: utc), Copy.removedLine)
    }

    /// Fix round 1: the caption and footnote describe the origin of the
    /// shown value, from the same inputs as `shownValue`.
    func testOriginFollowsTheShownValue() {
        let byDefault = AccountPurgeStatus(enabled: true, enabledBy: "default")
        // Default, toggled off and back on (a pending explicit true): the setting.
        let pendingOn = AccountPurgeStatus.shownOrigin(policy: nil, setting: true, status: byDefault)
        XCTAssertEqual(pendingOn, "setting")
        XCTAssertEqual(AccountPurgeStatus.footnote(byDefault, shown: true, origin: pendingOn), Copy.footOnAll)
        XCTAssertNil(AccountPurgeStatus.caption(byDefault, shown: true, origin: pendingOn))
        let pendingOff = AccountPurgeStatus.shownOrigin(policy: nil, setting: false, status: byDefault)
        XCTAssertEqual(AccountPurgeStatus.footnote(byDefault, shown: false, origin: pendingOff), Copy.footOff)

        // A forced value before the CLI answered: no "On by default".
        let forced = AccountPurgeStatus.shownOrigin(policy: true, setting: nil, status: nil)
        XCTAssertEqual(forced, "policy")
        XCTAssertNil(AccountPurgeStatus.caption(nil, shown: true, origin: forced))
        XCTAssertEqual(AccountPurgeStatus.footnote(nil, shown: true, origin: forced), Copy.footOnAll)

        // Nothing known: the default.
        let unknown = AccountPurgeStatus.shownOrigin(policy: nil, setting: nil, status: nil)
        XCTAssertEqual(AccountPurgeStatus.caption(nil, shown: true, origin: unknown), Copy.captionDefault)
        XCTAssertEqual(AccountPurgeStatus.footnote(nil, shown: true, origin: unknown), Copy.footDefault)
    }
}

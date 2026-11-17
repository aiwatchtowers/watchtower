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
}

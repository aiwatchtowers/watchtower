import XCTest
@testable import WatchtowerCore

/// The purge copy of the Slack policy hygiene spec (#1769) equals the
/// mockups' string table, `SlackPolicyMockCopy` (it lives in this test
/// target, so the comparison does too; WatchtowerCore pins its own strings).
final class AccountPurgeStatusCopyTests: XCTestCase {
    private typealias Copy = SlackPolicyMockCopy
    private let utc = TimeZone(secondsFromGMT: 0) ?? .current

    func testCopyMatchesMockups() {
        let byDefault = AccountPurgeStatus(enabled: false, enabledBy: "default")
        let bySetting = AccountPurgeStatus(enabled: true, enabledBy: "setting")
        let off = AccountPurgeStatus(enabled: false, enabledBy: "setting")

        XCTAssertEqual(AccountPurgeStatus.switchTitle, Copy.purgeTitle)
        XCTAssertEqual(AccountPurgeStatus.footnote(bySetting, shown: true), Copy.footOnAll)
        XCTAssertEqual(AccountPurgeStatus.footnote(nil, shown: true), Copy.footOnAll)
        XCTAssertEqual(AccountPurgeStatus.footnote(AccountPurgeStatus(enabled: true, enabledBy: "policy"), shown: true),
                       Copy.footOnAll)
        XCTAssertEqual(AccountPurgeStatus.footnote(off, shown: false), Copy.footOff)
        XCTAssertEqual(AccountPurgeStatus.footnote(byDefault, shown: false), Copy.footOff)

        XCTAssertEqual(AccountPurgeStatus.caption(byDefault, shown: false), Copy.captionDefault)
        XCTAssertEqual(AccountPurgeStatus.caption(nil, shown: false), Copy.captionDefault)
        XCTAssertNil(AccountPurgeStatus.caption(off, shown: false))
        XCTAssertNil(AccountPurgeStatus.caption(bySetting, shown: true))
        XCTAssertNil(AccountPurgeStatus.caption(byDefault, shown: true), "a pending on is the owner's, not the default")

        XCTAssertEqual(AccountPurgeStatus.removeDialogMessage(slackAccount: "acme", status: bySetting), Copy.removeBodyOn)
        XCTAssertEqual(AccountPurgeStatus.removeDialogMessage(slackAccount: "acme", status: byDefault), Copy.removeBodyOff)
        XCTAssertEqual(AccountPurgeStatus.removeDialogMessage(slackAccount: "acme", status: nil), Copy.removeBodyOff)
        XCTAssertEqual(AccountPurgeStatus.removeDialogMessage(slackAccount: "acme", status: off), Copy.removeBodyOff)
        XCTAssertEqual(AccountPurgeStatus.removeButton, Copy.remove)
    }

    func testZeroLeaseRemovedLineMatchesMockup() {
        let row = AccountPurge(id: 1, source: "slack", accountID: 2, accountLabel: "acme", accountStatus: "removed",
                               accessOkAt: PlanUsageDates.parse("2026-11-17T13:00:00Z"), reason: "lease",
                               dueAt: PlanUsageDates.parse("2026-11-20T14:00:00Z"))
        XCTAssertEqual(AccountPurgeNoticePolicy.line(row, zone: utc), Copy.removedLine)
    }

    /// Fix round 1: the caption describes the origin of the shown value,
    /// from the same inputs as `shownValue`.
    func testOriginFollowsTheShownValue() {
        let byDefault = AccountPurgeStatus(enabled: false, enabledBy: "default")
        // Default off, toggled on (a pending explicit true): the setting.
        let pendingOn = AccountPurgeStatus.shownOrigin(policy: nil, setting: true, status: byDefault)
        XCTAssertEqual(pendingOn, "setting")
        XCTAssertNil(AccountPurgeStatus.caption(byDefault, shown: true, origin: pendingOn))
        // Toggled on and back off (a pending explicit false): the owner's, no caption.
        let pendingOff = AccountPurgeStatus.shownOrigin(policy: nil, setting: false, status: byDefault)
        XCTAssertNil(AccountPurgeStatus.caption(byDefault, shown: false, origin: pendingOff))

        // A forced value before the CLI answered: no "Off by default".
        let forced = AccountPurgeStatus.shownOrigin(policy: false, setting: nil, status: nil)
        XCTAssertEqual(forced, "policy")
        XCTAssertNil(AccountPurgeStatus.caption(nil, shown: false, origin: forced))

        // Nothing known: the default.
        let unknown = AccountPurgeStatus.shownOrigin(policy: nil, setting: nil, status: nil)
        XCTAssertEqual(AccountPurgeStatus.caption(nil, shown: false, origin: unknown), Copy.captionDefault)
    }

    /// The notice follows Go's grace_hours (an organization's PurgeGraceHours);
    /// 0 reads as the next sync, never "0 hours".
    func testNoticeFollowsTheGraceHours() {
        let day = AccountPurgeStatus(enabled: true, enabledBy: "policy", graceHours: 24)
        XCTAssertTrue(AccountPurgeStatus.footnote(day, shown: true).contains("deleted 24 hours later"))
        XCTAssertTrue(AccountPurgeStatus.removeDialogMessage(slackAccount: "acme", status: day).contains("deleted in 24 hours"))

        let now = AccountPurgeStatus(enabled: true, enabledBy: "policy", graceHours: 0)
        let foot = AccountPurgeStatus.footnote(now, shown: true)
        XCTAssertTrue(foot.contains("deleted at the next sync unless you reconnect"), foot)
        XCTAssertTrue(foot.contains("goes at the next sync after the remove"), foot)
        XCTAssertFalse(foot.contains("0 hours"), foot)
        let dialog = AccountPurgeStatus.removeDialogMessage(slackAccount: "acme", status: now)
        XCTAssertTrue(dialog.contains("deleted at the next sync unless"), dialog)
        let jira = AccountPurgeStatus.removeDialogMessage("Kept.", status: now)
        XCTAssertEqual(jira, "Kept. Because deleting data on revoked access is on, it is deleted about "
            + "30 days after the account was last reached.")
    }
}

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
        XCTAssertEqual(AccountPurgeStatus.footnote(bySetting, policy: .none, shown: true), Copy.footOnAll)
        XCTAssertEqual(AccountPurgeStatus.footnote(nil, policy: .none, shown: true), Copy.footOnAll)
        let byPolicy = AccountPurgeStatus(enabled: true, enabledBy: "policy")
        XCTAssertEqual(AccountPurgeStatus.footnote(byPolicy, policy: .none, shown: true), Copy.footOnAll)
        XCTAssertEqual(AccountPurgeStatus.footnote(off, policy: .none, shown: false), Copy.footOff)
        XCTAssertEqual(AccountPurgeStatus.footnote(byDefault, policy: .none, shown: false), Copy.footOff)

        XCTAssertEqual(AccountPurgeStatus.caption(byDefault, shown: false), Copy.captionDefault)
        XCTAssertNil(AccountPurgeStatus.caption(nil, shown: false), "unknown: a build may turn it on")
        XCTAssertNil(AccountPurgeStatus.caption(off, shown: false))
        XCTAssertNil(AccountPurgeStatus.caption(bySetting, shown: true))
        XCTAssertNil(AccountPurgeStatus.caption(byDefault, shown: true), "a pending on is the owner's, not the default")

        func remove(_ status: AccountPurgeStatus?) -> String {
            AccountPurgeStatus.removeDialogMessage(slackAccount: "acme", status: status, policy: .none, setting: nil)
        }
        XCTAssertEqual(remove(bySetting), Copy.removeBodyOn)
        XCTAssertEqual(remove(byDefault), Copy.removeBodyOff)
        XCTAssertEqual(remove(off), Copy.removeBodyOff)
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

        // Nothing known (the CLI has not answered or failed): no claim, a
        // build may turn the purge on.
        let unknown = AccountPurgeStatus.shownOrigin(policy: nil, setting: nil, status: nil)
        XCTAssertNil(AccountPurgeStatus.caption(nil, shown: false, origin: unknown))
    }

    /// The notice follows Go's grace_hours (an organization's PurgeGraceHours);
    /// 0 reads as after the next (a removed workspace: a later) sync, never
    /// "0 hours"; the 30-day rule always warns 72 hours before the mark.
    func testNoticeFollowsTheGraceHours() {
        let day = AccountPurgeStatus(enabled: true, enabledBy: "policy", graceHours: 24)
        XCTAssertTrue(AccountPurgeStatus.footnote(day, policy: .none, shown: true).contains("deleted 24 hours later"))
        XCTAssertTrue(AccountPurgeStatus.removeDialogMessage(slackAccount: "acme", status: day, policy: .none, setting: nil)
            .contains("deleted in 24 hours"))

        let now = AccountPurgeStatus(enabled: true, enabledBy: "policy", graceHours: 0)
        let foot = AccountPurgeStatus.footnote(now, policy: .none, shown: true)
        XCTAssertTrue(foot.contains("deleted after the next sync unless you reconnect"), foot)
        XCTAssertTrue(foot.contains("goes after a later sync"), foot)
        XCTAssertFalse(foot.contains("0 hours"), foot)
        XCTAssertTrue(foot.contains("a notice comes 72 hours before that 30-day mark and the data is deleted at the mark"),
                      foot)
        let dialog = AccountPurgeStatus.removeDialogMessage(slackAccount: "acme", status: now, policy: .none, setting: nil)
        XCTAssertTrue(dialog.contains("deleted after a later sync unless"), dialog)
        let jira = AccountPurgeStatus.removeDialogMessage("Kept.", status: now, policy: .none, setting: nil)
        XCTAssertEqual(jira, "Kept. Because deleting data on revoked access is on, it is deleted about "
            + "30 days after the account was last reached, after a later sync.")
        XCTAssertTrue(foot.contains("another removed account's 30 days after it was last reached, after a later sync."),
                      foot)
    }

    /// The organization's PurgeGraceHours sets the footnote's notice before
    /// a stale CLI status; past 72 hours the 30-day rule deletes that long
    /// after its 72-hour warning, not at the mark.
    func testFootnoteGraceFromPolicyAndLongNotice() {
        var policy = ManagedPolicy()
        policy.purgeGraceHours = 240
        let stale = AccountPurgeStatus(enabled: true, enabledBy: "policy", graceHours: 72)
        let foot = AccountPurgeStatus.footnote(stale, policy: policy, shown: true)
        XCTAssertTrue(foot.contains("deleted 240 hours later unless you reconnect"), foot)
        XCTAssertTrue(foot.contains("a notice comes 72 hours before that 30-day mark and the data is deleted "
            + "240 hours after that notice"), foot)
        XCTAssertTrue(foot.contains("goes 240 hours after the remove"), foot)
        XCTAssertTrue(foot.contains("30 days after it was last reached, plus 240 hours' notice."), foot)
    }
}

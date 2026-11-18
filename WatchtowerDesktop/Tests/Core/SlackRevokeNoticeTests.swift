import XCTest
@testable import WatchtowerCore

/// #1769 (A3): `slack remove` / `auth logout` exit 0 and print this warning
/// when Slack did not confirm the revoke; the Desktop finds it in the output
/// by its exact text (the Go side pins the same string,
/// `TestSlackRevokeWarning_MatchesDesktopModel`).
final class SlackRevokeNoticeTests: XCTestCase {
    func testCLIWarningText() {
        XCTAssertEqual(
            SlackRevokeNotice.cliWarning,
            "Slack did not confirm the token was revoked; it may stay valid until a workspace admin removes the app"
        )
    }

    func testNoticeFoundInTheCLIOutput() {
        let out = SlackRevokeNotice.cliWarning + "\nRemoved account 1. Its synced data was kept."
        XCTAssertEqual(SlackRevokeNotice.notice(inCLIOutput: out), SlackRevokeNotice.cliWarning)
        XCTAssertNil(SlackRevokeNotice.notice(inCLIOutput: "Removed account 1. Its synced data was kept."))
        XCTAssertNil(SlackRevokeNotice.notice(inCLIOutput: ""))
    }
}

import XCTest
@testable import WatchtowerMobile

/// Settings → Accounts' status words the Mac's heartbeat sends.
final class AccountStatusStyleTests: XCTestCase {
    /// Slack with no synced account and Live on: the Mac sends one Slack row
    /// with status "live" (`internal/hub/slices` `DBAccounts`, screens spec
    /// §2.3). It reads as text in secondary, never as an error.
    func testLiveOnly() {
        let live = AccountStatusStyle(status: "live")
        XCTAssertEqual(live.mark, .textOnly)
        XCTAssertEqual(live.text, "Live only — sync needs your workspace's app")
        XCTAssertEqual([live.tone, live.textTone], [.secondary, .secondary])
        XCTAssertTrue(live.toneUses.allSatisfy { $0.role == .info })
    }

    /// A status this phone does not know (a newer Mac's) shows its raw word.
    func testUnknownStatusShowsRaw() {
        let newer = AccountStatusStyle(status: "paused")
        XCTAssertEqual(newer.mark, .textOnly)
        XCTAssertEqual(newer.text, "paused")
        XCTAssertEqual([newer.tone, newer.textTone], [.secondary, .secondary])
    }
}

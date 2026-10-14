import XCTest
import GRDB
@testable import WatchtowerCore

final class CalendarSyncHealthTests: XCTestCase {

    private func account(id: Int = 1, calendar: Bool = true, status: String = "ok", error: String = "") -> GoogleAccount {
        GoogleAccount(row: [
            "id": id, "email": "owner@example.com", "calendar_enabled": calendar,
            "gmail_enabled": false, "status": status, "error": error
        ])
    }

    private func evaluate(
        _ accounts: [GoogleAccount],
        calDAV: Bool = false,
        switchOn: Bool = true,
        google: Int = 0,
        calDAVCount: Int = 0,
        daemon: Bool = true
    ) -> CalendarSyncHealth {
        CalendarSyncHealth.evaluate(
            accounts: accounts, hasCalDAVSource: calDAV, syncSwitchOn: switchOn,
            googleCalendarCount: google, calDAVCalendarCount: calDAVCount, daemonRunning: daemon)
    }

    /// #740: the account onboarding connected, with the switch still off —
    /// the exact state that left the tab empty with no explanation.
    func testConnectedGoogleCalendarWithSwitchOffIsSyncOff() {
        XCTAssertEqual(evaluate([account()], switchOn: false), .syncOff)
        // Even with calendars left over from an earlier sync.
        XCTAssertEqual(evaluate([account()], calDAV: true, switchOn: false, google: 2, calDAVCount: 1), .syncOff)
    }

    func testSwitchOnNothingSyncedYetIsAwaitingFirstSync() {
        XCTAssertEqual(evaluate([account()]), .awaitingFirstSync)
    }

    /// Never synced and no daemon to sync it: say so instead of a spinner
    /// that promises a minute forever.
    func testNothingSyncedAndNoDaemonIsDaemonStopped() {
        XCTAssertEqual(evaluate([account()], daemon: false), .daemonStopped)
        XCTAssertEqual(evaluate([], calDAV: true, daemon: false), .daemonStopped)
    }

    func testSyncedIsOK() {
        XCTAssertEqual(evaluate([account()], google: 1), .ok)
        // A stopped daemon is not a reason once everything has synced.
        XCTAssertEqual(evaluate([account()], google: 1, daemon: false), .ok)
    }

    func testFailedAccountIsAccountError() {
        let broken = account(id: 2, status: "revoked", error: "token revoked")
        XCTAssertEqual(evaluate([broken]), .accountError(broken))
        // A healthy sibling does not hide the broken one.
        XCTAssertEqual(evaluate([account(), broken], google: 2), .accountError(broken))
        // With the switch off and no healthy account, the switch is not the
        // problem yet — Turn On could not help a broken grant.
        XCTAssertEqual(evaluate([broken], switchOn: false), .accountError(broken))
    }

    /// "Most actionable first": with a healthy account the off switch wins
    /// over a broken sibling.
    func testSyncOffOutranksASiblingError() {
        let broken = account(id: 2, status: "error", error: "dial tcp: timeout")
        XCTAssertEqual(evaluate([account(), broken], switchOn: false), .syncOff)
    }

    /// The counts are per source: a synced CalDAV calendar does not hide a
    /// Google calendar that never synced, and vice versa.
    func testCountsArePerSource() {
        XCTAssertEqual(evaluate([account()], calDAV: true, google: 0, calDAVCount: 3), .awaitingFirstSync)
        XCTAssertEqual(evaluate([account()], calDAV: true, google: 2, calDAVCount: 0), .awaitingFirstSync)
        XCTAssertEqual(evaluate([account()], calDAV: true, google: 2, calDAVCount: 1), .ok)
    }

    /// CalDAV/ICS is not behind `calendar.enabled`: a CalDAV-only install
    /// with the switch off is fine.
    func testCalDAVOnlyIgnoresTheSwitch() {
        XCTAssertEqual(evaluate([], calDAV: true, switchOn: false, calDAVCount: 1), .ok)
        XCTAssertEqual(evaluate([], calDAV: true, switchOn: false), .awaitingFirstSync)
    }

    /// Degenerate: no calendar source at all, or a Gmail-only Google account.
    func testNoCalendarSourceIsOK() {
        XCTAssertEqual(evaluate([], switchOn: false, daemon: false), .ok)
        XCTAssertEqual(evaluate([account(calendar: false, status: "error")], switchOn: false), .ok)
    }
}

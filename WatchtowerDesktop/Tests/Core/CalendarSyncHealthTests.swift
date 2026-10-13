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

    /// #740: the account onboarding connected, with the switch still off —
    /// the exact state that left the tab empty with no explanation.
    func testConnectedGoogleCalendarWithSwitchOffIsSyncOff() {
        XCTAssertEqual(
            CalendarSyncHealth.evaluate(accounts: [account()], hasCalDAVSource: false, syncSwitchOn: false, calendarCount: 0),
            .syncOff
        )
        // Even with calendars left over from an earlier sync.
        XCTAssertEqual(
            CalendarSyncHealth.evaluate(accounts: [account()], hasCalDAVSource: true, syncSwitchOn: false, calendarCount: 3),
            .syncOff
        )
    }

    func testSwitchOnNothingSyncedYetIsAwaitingFirstSync() {
        XCTAssertEqual(
            CalendarSyncHealth.evaluate(accounts: [account()], hasCalDAVSource: false, syncSwitchOn: true, calendarCount: 0),
            .awaitingFirstSync
        )
    }

    func testSyncedIsOK() {
        XCTAssertEqual(
            CalendarSyncHealth.evaluate(accounts: [account()], hasCalDAVSource: false, syncSwitchOn: true, calendarCount: 1),
            .ok
        )
    }

    func testBrokenGrantNeedsReconnect() {
        let broken = account(id: 2, status: "revoked", error: "token revoked")
        XCTAssertEqual(
            CalendarSyncHealth.evaluate(accounts: [broken], hasCalDAVSource: false, syncSwitchOn: true, calendarCount: 0),
            .needsReconnect(broken)
        )
        // A healthy sibling does not hide the broken one.
        XCTAssertEqual(
            CalendarSyncHealth.evaluate(accounts: [account(), broken], hasCalDAVSource: false, syncSwitchOn: true, calendarCount: 2),
            .needsReconnect(broken)
        )
    }

    /// CalDAV/ICS is not behind `calendar.enabled`: a CalDAV-only install
    /// with the switch off is fine.
    func testCalDAVOnlyIgnoresTheSwitch() {
        XCTAssertEqual(
            CalendarSyncHealth.evaluate(accounts: [], hasCalDAVSource: true, syncSwitchOn: false, calendarCount: 1),
            .ok
        )
        XCTAssertEqual(
            CalendarSyncHealth.evaluate(accounts: [], hasCalDAVSource: true, syncSwitchOn: false, calendarCount: 0),
            .awaitingFirstSync
        )
    }

    /// Degenerate: a Gmail-only Google account and no calendar source at all.
    func testNoCalendarSourceIsOK() {
        XCTAssertEqual(
            CalendarSyncHealth.evaluate(accounts: [], hasCalDAVSource: false, syncSwitchOn: false, calendarCount: 0),
            .ok
        )
        XCTAssertEqual(
            CalendarSyncHealth.evaluate(
                accounts: [account(calendar: false, status: "error")], hasCalDAVSource: false,
                syncSwitchOn: false, calendarCount: 0),
            .ok
        )
    }
}

import GRDB
import XCTest
@testable import WatchtowerCore

/// The Desktop twin of Go's netsec rule for accounts: the add sheets refuse
/// a cleartext password inline, and an account the sync stopped for it is
/// recognised by Go's `netsec.StatusPrefix` on its row error.
final class CleartextRefusalTests: XCTestCase {
    func testAStoppedAccountIsRecognisedByThePrefix() {
        let mail = EmailAccount(row: Row([
            "id": 1, "provider": "imap", "status": "error",
            "error": "transport: imap: a secret would be sent unencrypted: …"
        ]))
        XCTAssertTrue(mail.isStoppedForCleartext)
        let wrongPassword = EmailAccount(row: Row(["id": 2, "provider": "imap", "status": "error", "error": "auth failed"]))
        XCTAssertFalse(wrongPassword.isStoppedForCleartext)
        let calendar = CalendarAccount(row: Row([
            "id": 3, "provider": "caldav", "status": "error", "error": "transport: caldav: a secret would be sent unencrypted"
        ]))
        XCTAssertTrue(calendar.isStoppedForCleartext)
        let healthy = CalendarAccount(row: Row(["id": 4, "provider": "caldav", "status": "ok", "error": ""]))
        XCTAssertFalse(healthy.isStoppedForCleartext)
    }

    func testIMAPNoneOnlyForLoopback() {
        XCTAssertTrue(CleartextRefusal.refusesNoTLS(host: "imap.example.com"))
        XCTAssertFalse(CleartextRefusal.refusesNoTLS(host: "127.0.0.1"))
        XCTAssertFalse(CleartextRefusal.refusesNoTLS(host: " localhost "))
        XCTAssertFalse(CleartextRefusal.refusesNoTLS(host: ""), "nothing typed yet is not a refusal")
    }

    func testCalDAVOnlyHTTPSOrLoopback() {
        XCTAssertTrue(CleartextRefusal.refusesCalDAV(url: "http://dav.example.com/"))
        XCTAssertFalse(CleartextRefusal.refusesCalDAV(url: "https://dav.example.com/"))
        XCTAssertFalse(CleartextRefusal.refusesCalDAV(url: "http://localhost:5232/"))
    }
}

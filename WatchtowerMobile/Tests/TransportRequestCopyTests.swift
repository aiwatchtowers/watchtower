import XCTest
@testable import WatchtowerMobile

/// The refusals of a request toward iCloud and their texts (relay client Phase 4 Task 5; the approved wording of
/// Phase 3b decision 3 and the mockup's S52).
final class TransportRequestCopyTests: XCTestCase {
    func testUnavailable() {
        XCTAssertEqual(
            TransportRequestRefusal.unavailable.message(macName: "Work Mac"),
            "Work Mac couldn't switch right now. Try again in a minute.")
    }

    func testNotSupported() {
        XCTAssertEqual(
            TransportRequestRefusal.notSupported.message(macName: "Work Mac"),
            "Work Mac can't switch from here. Update Watchtower on the Mac.")
    }

    func testNotOrdered() {
        XCTAssertEqual(
            TransportRequestRefusal.notOrdered.message(macName: "Work Mac"),
            "Update Watchtower on Work Mac to change how it connects.")
    }

    func testMacNoAnswer() {
        XCTAssertEqual(
            TransportRequestRefusal.macNoAnswer.message(macName: "Work Mac"),
            "Work Mac didn't answer for a day, so nothing changed. Try again when it's back.")
    }

    func testLapseNoAnswer() {
        XCTAssertEqual(
            TransportRequestRefusal.lapseNoAnswer.message(macName: "Work Mac"),
            "Work Mac didn't answer for a day. It moves to iCloud when it's back.")
    }

    func testTheAnswerLimitIsTheReaderWaitLimit() {
        XCTAssertEqual(TransportRequest.answerLimit, RelayUpgrade.readerWaitLimit)
        XCTAssertEqual(TransportRequest.answerLimit, 24 * 3600)
    }

    func testTheRecordRoundTripsWithItsRefusal() throws {
        var record = TransportRequestRecord(
            target: .cloudKit, controlID: "C-1", reason: "entitlement_expired", at: Date(timeIntervalSince1970: 1_800_000_000))
        record.refusal = .lapseNoAnswer
        let back = try JSONDecoder().decode(TransportRequestRecord.self, from: try JSONEncoder().encode(record))
        XCTAssertEqual(back, record)
    }
}

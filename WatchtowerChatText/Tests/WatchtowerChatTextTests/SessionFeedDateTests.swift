import XCTest
@testable import WatchtowerChatText

/// The session feed's timestamps (`SessionFeedDate.parse`): RFC 3339 with or
/// without fractional seconds, any offset; Go's zero time and junk are no time.
final class SessionFeedDateTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z

    func testPlainAndFractionalSeconds() throws {
        XCTAssertEqual(SessionFeedDate.parse("2027-01-15T08:00:00Z"), base)
        let fractional = try XCTUnwrap(SessionFeedDate.parse("2027-01-15T08:00:00.250Z"))
        XCTAssertEqual(fractional.timeIntervalSince(base), 0.25, accuracy: 0.0001)
    }

    func testOffsetIsTheSameInstant() {
        XCTAssertEqual(SessionFeedDate.parse("2027-01-15T11:00:00+03:00"), base)
        XCTAssertEqual(SessionFeedDate.parse("2027-01-15T03:00:00.000-05:00"), base)
    }

    func testZeroTimeEmptyAndJunkAreNoTime() {
        XCTAssertNil(SessionFeedDate.parse("0001-01-01T00:00:00Z"), "Go's zero time")
        XCTAssertNil(SessionFeedDate.parse(""))
        XCTAssertNil(SessionFeedDate.parse(nil))
        XCTAssertNil(SessionFeedDate.parse("yesterday"))
    }
}

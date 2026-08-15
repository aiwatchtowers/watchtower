import XCTest
@testable import WatchtowerCore

final class SlackAccountIDTests: XCTestCase {

    // MARK: - split

    func testSplitNamespacedID() {
        let result = SlackAccountID.split("1:U01CAHRV7M3")
        XCTAssertEqual(result?.accountID, 1)
        XCTAssertEqual(result?.rawID, "U01CAHRV7M3")
    }

    func testSplitBareIDReturnsNil() {
        XCTAssertNil(SlackAccountID.split("U01CAHRV7M3"))
    }

    func testSplitNonDigitPrefixReturnsNil() {
        // "abc:U1" must NOT be treated as namespaced — the prefix isn't a plain integer.
        XCTAssertNil(SlackAccountID.split("abc:U1"))
    }

    // MARK: - raw

    func testRawStripsNamespace() {
        XCTAssertEqual(SlackAccountID.raw("1:U01CAHRV7M3"), "U01CAHRV7M3")
    }

    func testRawLeavesBareIDUnchanged() {
        XCTAssertEqual(SlackAccountID.raw("U01CAHRV7M3"), "U01CAHRV7M3")
    }

    func testRawLeavesNonNamespacedColonStringUnchanged() {
        XCTAssertEqual(SlackAccountID.raw("abc:U1"), "abc:U1")
    }

    // MARK: - matches

    func testMatchesBareStoredAgainstNamespacedList() {
        XCTAssertTrue(SlackAccountID.matches("1:U01CAHRV7M3", "U01CAHRV7M3"))
    }

    func testMatchesNamespacedStoredAgainstNamespacedList() {
        XCTAssertTrue(SlackAccountID.matches("1:U01CAHRV7M3", "1:U01CAHRV7M3"))
    }

    func testMatchesDifferentRawIDsDoNotMatch() {
        XCTAssertFalse(SlackAccountID.matches("1:U01CAHRV7M3", "U0OTHERID"))
    }

    func testMatchesNonNamespacedArbitraryStringFallsBackToItself() {
        XCTAssertTrue(SlackAccountID.matches("some-arbitrary-id", "some-arbitrary-id"))
        // "abc" isn't a digit-only prefix, so this is not treated as namespaced.
        XCTAssertFalse(SlackAccountID.matches("some-arbitrary-id", "abc:some-arbitrary-id"))
    }
}

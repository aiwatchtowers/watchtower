import XCTest
@testable import WatchtowerCore

final class SlackAccountIDTests: XCTestCase {

    // MARK: - split

    func testSplitNamespacedID() {
        let result = SlackAccountID.split("1:U0FAKE01")
        XCTAssertEqual(result?.accountID, 1)
        XCTAssertEqual(result?.rawID, "U0FAKE01")
    }

    func testSplitBareIDReturnsNil() {
        XCTAssertNil(SlackAccountID.split("U0FAKE01"))
    }

    func testSplitNonDigitPrefixReturnsNil() {
        // "abc:U1" must NOT be treated as namespaced — the prefix isn't a plain integer.
        XCTAssertNil(SlackAccountID.split("abc:U1"))
    }

    // MARK: - raw

    func testRawStripsNamespace() {
        XCTAssertEqual(SlackAccountID.raw("1:U0FAKE01"), "U0FAKE01")
    }

    func testRawLeavesBareIDUnchanged() {
        XCTAssertEqual(SlackAccountID.raw("U0FAKE01"), "U0FAKE01")
    }

    func testRawLeavesNonNamespacedColonStringUnchanged() {
        XCTAssertEqual(SlackAccountID.raw("abc:U1"), "abc:U1")
    }

    // MARK: - matches

    func testMatchesBareStoredAgainstNamespacedList() {
        XCTAssertTrue(SlackAccountID.matches("1:U0FAKE01", "U0FAKE01"))
    }

    func testMatchesNamespacedStoredAgainstNamespacedList() {
        XCTAssertTrue(SlackAccountID.matches("1:U0FAKE01", "1:U0FAKE01"))
    }

    func testMatchesDifferentRawIDsDoNotMatch() {
        XCTAssertFalse(SlackAccountID.matches("1:U0FAKE01", "U0OTHERID"))
    }

    func testMatchesNonNamespacedArbitraryStringFallsBackToItself() {
        XCTAssertTrue(SlackAccountID.matches("some-arbitrary-id", "some-arbitrary-id"))
        // "abc" isn't a digit-only prefix, so this is not treated as namespaced.
        XCTAssertFalse(SlackAccountID.matches("some-arbitrary-id", "abc:some-arbitrary-id"))
    }
}

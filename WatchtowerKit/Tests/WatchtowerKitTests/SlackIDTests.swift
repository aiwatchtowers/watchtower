/// Plain import (no @testable): these are the public helper's own semantics,
/// exercised the way `DemoSeed` (app target) calls it. The public surface
/// itself is pinned by `PublicAPISurfaceTests`.
import WatchtowerKit
import XCTest

final class SlackIDTests: XCTestCase {
    func testSplitNamespacedID() {
        let (accountID, rawID, isNamespaced) = SlackID.split("1:C0123")
        XCTAssertEqual(accountID, 1)
        XCTAssertEqual(rawID, "C0123")
        XCTAssertTrue(isNamespaced)
    }

    func testSplitBareIDIsNotNamespaced() {
        let (accountID, rawID, isNamespaced) = SlackID.split("C0123")
        XCTAssertEqual(accountID, 0)
        XCTAssertEqual(rawID, "C0123")
        XCTAssertFalse(isNamespaced)
    }

    /// A leading colon means there is no account prefix — Go's `idx <= 0`
    /// branch returns the input untouched, colon included.
    func testSplitLeadingColonReturnsInputUnchanged() {
        let (accountID, rawID, isNamespaced) = SlackID.split(":C0123")
        XCTAssertEqual(accountID, 0)
        XCTAssertEqual(rawID, ":C0123")
        XCTAssertFalse(isNamespaced)
    }

    func testSplitNonNumericPrefixReturnsInputUnchanged() {
        let (accountID, rawID, isNamespaced) = SlackID.split("x:C0123")
        XCTAssertEqual(accountID, 0)
        XCTAssertEqual(rawID, "x:C0123")
        XCTAssertFalse(isNamespaced)
    }

    func testSplitUsesFirstColonOnly() {
        let (accountID, rawID, isNamespaced) = SlackID.split("1:2:C0123")
        XCTAssertEqual(accountID, 1)
        XCTAssertEqual(rawID, "2:C0123")
        XCTAssertTrue(isNamespaced)
    }

    func testSplitEmptyID() {
        let (accountID, rawID, isNamespaced) = SlackID.split("")
        XCTAssertEqual(accountID, 0)
        XCTAssertEqual(rawID, "")
        XCTAssertFalse(isNamespaced)
    }

    /// Slack message timestamps flow through the same models as ids; a ts has
    /// no colon, so it must survive a split untouched.
    func testSplitLeavesMessageTimestampUntouched() {
        let (accountID, rawID, isNamespaced) = SlackID.split("1712345678.000100")
        XCTAssertEqual(accountID, 0)
        XCTAssertEqual(rawID, "1712345678.000100")
        XCTAssertFalse(isNamespaced)
    }

    func testNamespacedID() {
        XCTAssertEqual(SlackID.namespaced(accountID: 1, rawID: "C0123"), "1:C0123")
    }

    func testNamespacedEmptyRawIDStaysEmpty() {
        XCTAssertEqual(SlackID.namespaced(accountID: 1, rawID: ""), "")
    }

    func testNamespaceRoundTrip() {
        let (accountID, rawID, isNamespaced) = SlackID.split(SlackID.namespaced(accountID: 7, rawID: "U9"))
        XCTAssertEqual(accountID, 7)
        XCTAssertEqual(rawID, "U9")
        XCTAssertTrue(isNamespaced)
    }
}

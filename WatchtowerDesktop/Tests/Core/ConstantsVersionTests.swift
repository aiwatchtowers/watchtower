import XCTest
@testable import WatchtowerCore

/// `Constants.stripLeadingV` — a build invoked with a "v"-prefixed VERSION
/// (e.g. copied from a git tag) must not double up with a call site that
/// prepends its own "v" (`StatusBarView` renders "v\(Constants.appVersion)"),
/// which produced the reported "vv0.10.1-…" status bar string.
final class ConstantsVersionTests: XCTestCase {
    func testStripsLowercaseVPrefix() {
        XCTAssertEqual(Constants.stripLeadingV("v0.10.1"), "0.10.1")
    }

    func testStripsUppercaseVPrefix() {
        XCTAssertEqual(Constants.stripLeadingV("V0.10.1"), "0.10.1")
    }

    func testLeavesAnUnprefixedVersionUnchanged() {
        XCTAssertEqual(Constants.stripLeadingV("0.10.1"), "0.10.1")
    }

    func testOnlyStripsOneLeadingV() {
        // A malformed double-prefixed input still leaves a single "v" — this
        // function fixes the doubling at the source (the build string
        // itself), not every possible input shape.
        XCTAssertEqual(Constants.stripLeadingV("vv0.10.1"), "v0.10.1")
    }
}

import XCTest
@testable import WatchtowerDesktop

/// The design gallery exists only in `make app-dev` bundles, which carry the
/// `WTDevBuild` Info.plist stamp; anything else leaves it off.
final class DevBuildTests: XCTestCase {
    func testMissingStampIsOff() {
        XCTAssertFalse(DevBuild.isEnabled(info: [:]))
        XCTAssertFalse(DevBuild.isEnabled(info: nil))
    }

    func testFalseStampIsOff() {
        XCTAssertFalse(DevBuild.isEnabled(info: ["WTDevBuild": false]))
    }

    func testTrueStampIsOn() {
        XCTAssertTrue(DevBuild.isEnabled(info: ["WTDevBuild": true]))
    }
}

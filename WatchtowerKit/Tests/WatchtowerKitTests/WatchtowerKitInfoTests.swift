import XCTest
@testable import WatchtowerKit

final class WatchtowerKitInfoTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertFalse(WatchtowerKitInfo.version.isEmpty)
    }
}

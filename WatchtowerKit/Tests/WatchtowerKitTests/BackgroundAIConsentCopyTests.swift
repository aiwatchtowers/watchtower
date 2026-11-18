import WatchtowerKit
import WatchtowerSync
import XCTest

final class BackgroundAIConsentCopyTests: XCTestCase {
    func testPhoneLines() {
        XCTAssertEqual(
            BackgroundAIConsentCopy.phoneLine(.paused),
            "Digests and briefings aren't updating: background AI is paused on your Mac. Allow it in Watchtower on the Mac."
        )
        XCTAssertEqual(
            BackgroundAIConsentCopy.phoneLine(.organization),
            "Digests and briefings aren't updating: your organization turned background AI off."
        )
        XCTAssertNil(BackgroundAIConsentCopy.phoneLine(.allowed))
        XCTAssertNil(BackgroundAIConsentCopy.phoneLine(nil))
    }
}

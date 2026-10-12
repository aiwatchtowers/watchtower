import UIKit
import XCTest
@testable import WatchtowerMobile

/// Design pass O1: Welcome shows the app icon and three lines on what the
/// phone does.
final class WelcomeTests: XCTestCase {
    func testTheAppIconImageShipsInTheAssetCatalog() {
        XCTAssertNotNil(UIImage(named: "AppIconImage"), "the drawable copy of the app icon")
    }

    func testWelcomeNamesThreeThingsThePhoneDoes() {
        XCTAssertEqual(WelcomeFeature.all.map(\.symbol), ["questionmark.bubble", "terminal", "calendar"])
        XCTAssertEqual(
            WelcomeFeature.all.map(\.text),
            ["Answer your agents' asks", "Follow and start sessions", "Record and recap meetings"]
        )
    }
}

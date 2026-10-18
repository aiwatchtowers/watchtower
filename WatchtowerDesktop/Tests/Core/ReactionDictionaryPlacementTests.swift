import XCTest
@testable import WatchtowerCore

final class ReactionDictionaryPlacementTests: XCTestCase {
    func testEditorMovesToAutomationsWhenTheTabIsVisible() {
        XCTAssertFalse(ReactionDictionaryPlacement.showsEditorInSettings(automationsVisible: true))
    }

    func testSettingsKeepsTheEditorWhileAutomationsIsHidden() {
        XCTAssertTrue(ReactionDictionaryPlacement.showsEditorInSettings(automationsVisible: false))
    }
}

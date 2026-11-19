import XCTest
@testable import ChatUI
import WatchtowerChatText

/// Where a ⌘V goes (#2065 §6): with `inlinePastes` (the Workchat) an image and a long text become inline tokens;
/// without it (the AI chat) an image is a chip and a long text gets the "Attach as file" offer, as before.
final class ComposerPasteRouteTests: XCTestCase {
    func testWorkchatRoutesImagesAndLongTextToTokens() {
        XCTAssertEqual(ComposerPasteRoute.route(isImage: true, characterCount: 0, inlinePastes: true), .token)
        XCTAssertEqual(ComposerPasteRoute.route(isImage: false, characterCount: PasteClassifier.longTextThreshold,
                                                inlinePastes: true), .token)
        XCTAssertEqual(ComposerPasteRoute.route(isImage: false, characterCount: 20, inlinePastes: true), .plain)
    }

    func testAIChatKeepsChipAndOffer() {
        XCTAssertEqual(ComposerPasteRoute.route(isImage: true, characterCount: 0, inlinePastes: false), .chip)
        XCTAssertEqual(ComposerPasteRoute.route(isImage: false, characterCount: PasteClassifier.longTextThreshold,
                                                inlinePastes: false), .offerAsFile)
        XCTAssertEqual(ComposerPasteRoute.route(isImage: false, characterCount: 20, inlinePastes: false), .plain)
    }

    func testInlinePastesDefaultsOff() {
        XCTAssertFalse(ChatComposerFieldConfig(placeholder: "Ask").inlinePastes)
    }
}

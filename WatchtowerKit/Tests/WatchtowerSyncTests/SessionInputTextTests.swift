import XCTest
@testable import WatchtowerSync

/// The `session_input` text rule both sides apply (PROJ-16).
final class SessionInputTextTests: XCTestCase {
    func testLineBreaksAndControlsBecomeOneSpaceEachAndCRLFOne() {
        XCTAssertEqual(SessionInputText.normalize("  a\r\nb\nc\rd\u{1B}[2Je\u{2028}f  "), "a b c d [2Je f")
    }

    func testFormatCharactersStay() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(SessionInputText.normalize("hi \(family)"), "hi \(family)")
        XCTAssertEqual(SessionInputText.normalize(family).count, 1)
    }

    func testTheCapCountsCharactersAfterNormalizing() {
        XCTAssertFalse(SessionInputText.isSendable(" \n\t "))
        XCTAssertTrue(SessionInputText.isSendable(String(repeating: "a", count: 4000)))
        XCTAssertFalse(SessionInputText.isSendable(String(repeating: "a", count: 4001)))
        XCTAssertTrue(SessionInputText.isSendable("  " + String(repeating: "a", count: 4000) + "\r\n"), "trimmed first")
    }
}

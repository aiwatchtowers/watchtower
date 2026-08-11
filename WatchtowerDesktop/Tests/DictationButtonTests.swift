import XCTest
@testable import WatchtowerDesktop

/// `DictationSpan` is the pure span-management core of `DictationButton`,
/// extracted so these tests don't need ViewInspector.
final class DictationSpanTests: XCTestCase {

    // MARK: - base

    func test_baseEmptyField_returnsExistingForIdeaAndChat() {
        XCTAssertEqual(DictationSpan.base(existing: "", mode: .idea), "")
        XCTAssertEqual(DictationSpan.base(existing: "", mode: .chat), "")
    }

    func test_baseNonEmptyNote_endsWithDoubleNewline() {
        XCTAssertEqual(DictationSpan.base(existing: "Existing notes", mode: .note),
                       "Existing notes\n\n")
    }

    func test_baseNonEmptyChat_endsWithSingleSpace() {
        let base = DictationSpan.base(existing: "hello", mode: .chat)
        XCTAssertEqual(base, "hello ")
        XCTAssertFalse(base.hasSuffix("  "))
    }

    // MARK: - compose

    func test_composeAppendsDictatedVerbatim() {
        // No trimming of the dictated chunk — leading/trailing whitespace in
        // what the engine returned is kept exactly as delivered.
        XCTAssertEqual(DictationSpan.compose(base: "hello ", dictated: "  world  "),
                       "hello   world  ")
    }

    func test_composeEmptyDictated_returnsOriginalExistingText() {
        let noteBase = DictationSpan.base(existing: "hello", mode: .note)
        XCTAssertEqual(DictationSpan.compose(base: noteBase, dictated: ""), "hello")

        let chatBase = DictationSpan.base(existing: "hello", mode: .chat)
        XCTAssertEqual(DictationSpan.compose(base: chatBase, dictated: ""), "hello")
    }
}

import ChatWire
import XCTest
@testable import WatchtowerCore
import WatchtowerChatText

final class MentionTokenizerTests: XCTestCase {
    private func utf16Count(_ s: String) -> Int { s.utf16.count }

    func testActiveQueryAtStartAndAfterSpace() {
        XCTAssertEqual(MentionTokenizer.activeQuery(text: "@an", cursor: 3), "an")
        XCTAssertEqual(MentionTokenizer.activeQuery(text: "ask @an", cursor: 7), "an")
        XCTAssertEqual(MentionTokenizer.activeQuery(text: "ask @", cursor: 5), "")
        XCTAssertEqual(MentionTokenizer.activeMention(text: "ask @an", cursor: 7), ComposerTrigger(start: 4, query: "an"))
    }

    func testNoTriggerInsideEmailOrAfterSpaceInQuery() {
        XCTAssertNil(MentionTokenizer.activeQuery(text: "anna@example.com", cursor: 16))
        XCTAssertNil(MentionTokenizer.activeQuery(text: "@anna ivanova", cursor: 13), "query ends at whitespace")
        XCTAssertNil(MentionTokenizer.activeQuery(text: "no mention", cursor: 10))
    }

    /// The same whitespace-boundary rule that keeps `anna@example.com` inert
    /// also keeps an `@` glued to a code span's backtick from opening —
    /// neither is preceded by whitespace or the start of the text.
    func testNoTriggerRightAfterACodeSpanBacktick() {
        XCTAssertNil(MentionTokenizer.activeQuery(text: "see `@decorator`", cursor: 6))
        XCTAssertNil(MentionTokenizer.activeQuery(text: "see `@decorator", cursor: 8),
                     "still glued to the backtick even without a closing one")
    }

    func testCursorInTheMiddleUsesTextBeforeCursorOnly() {
        let text = "ask @an about it"
        XCTAssertEqual(MentionTokenizer.activeQuery(text: text, cursor: 7), "an")
        XCTAssertNil(MentionTokenizer.activeQuery(text: text, cursor: text.utf16.count))
    }

    func testCursorIsUTF16Offset() {
        let text = "привет 👋 @Ив"
        XCTAssertEqual(MentionTokenizer.activeQuery(text: text, cursor: utf16Count(text)), "Ив")
    }

    func testOutOfRangeCursorIsNil() {
        XCTAssertNil(MentionTokenizer.activeQuery(text: "@a", cursor: 5))
        XCTAssertNil(MentionTokenizer.activeQuery(text: "@a", cursor: -1))
    }

    func testReplaceActiveQueryKeepsSuffixAndMovesCursor() {
        let edit = MentionTokenizer.replace(
            ComposerTrigger(start: 4, query: "an"), in: "ask @an about", cursor: 7, with: "@Anna Ivanova ")
        XCTAssertEqual(edit.text, "ask @Anna Ivanova  about")
        XCTAssertEqual(edit.cursor, 4 + "@Anna Ivanova ".utf16.count)
    }

    func testActiveSkillOnlyAtTheStartOfTheDraft() {
        XCTAssertEqual(MentionTokenizer.activeSkill(text: "/sta", cursor: 4), ComposerTrigger(start: 0, query: "sta"))
        XCTAssertEqual(MentionTokenizer.activeSkill(text: "  /", cursor: 3), ComposerTrigger(start: 2, query: ""))
        XCTAssertNil(MentionTokenizer.activeSkill(text: "see /usr", cursor: 8), "not the first word")
        XCTAssertNil(MentionTokenizer.activeSkill(text: "/usr/bin", cursor: 8), "second slash is mid-word")
        XCTAssertNil(MentionTokenizer.activeSkill(text: "/Status!", cursor: 8), "not a skill-name prefix")
        XCTAssertNil(MentionTokenizer.activeSkill(text: "/status now", cursor: 11), "query ended")
    }
}

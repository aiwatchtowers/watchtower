import XCTest
@testable import WatchtowerCore

final class CommentBatchComposerTests: XCTestCase {
    private typealias Item = CommentBatchComposer.Item

    func testOneMessageCarriesHeaderEveryItemClosingAndNoteInOrder() {
        let text = CommentBatchComposer.compose(
            header: "About these parts of your answers:",
            items: [Item(quote: "retry budget", heading: "Risks", comment: " Why so small? "),
                    Item(quote: "Ship on Friday", heading: "", comment: "  ")],
            closing: "Please revise.",
            note: "  Also: what about staging?\n"
        )
        XCTAssertEqual(text, """
            About these parts of your answers:

            1. Under "Risks":
            > retry budget
            Why so small?

            2. On this passage:
            > Ship on Friday

            Please revise.

            Also: what about staging?
            """)
    }

    func testNoItemsIsJustTheNoteAndNothingAtAllIsNil() {
        XCTAssertEqual(CommentBatchComposer.compose(header: "H", items: [], closing: "C", note: " hi "), "hi")
        XCTAssertNil(CommentBatchComposer.compose(header: "H", items: [], closing: "C", note: " \n"))
    }

    func testBlockquotePrefixesEveryLineAndKeepsBlankLinesInsideTheQuote() {
        XCTAssertEqual(CommentBatchComposer.blockquote("  first line\nsecond\n\n    indented  "),
                       "> first line\n> second\n>\n>     indented")
    }

    func testSendButtonTitle() {
        XCTAssertEqual(CommentBatchComposer.sendButtonTitle(count: 1), "Send 1 comment")
        XCTAssertEqual(CommentBatchComposer.sendButtonTitle(count: 3), "Send 3 comments")
    }
}

import XCTest
@testable import WatchtowerCore

final class ChatQuoteReplyTests: XCTestCase {
    func testArtifactFencesBecomeOneBracketedLine() {
        let text = """
        Intro text.

        :::artifact key="plan" kind="document" title="Plan"
        Body of the plan.
        :::

        Outro.
        """
        XCTAssertEqual(ChatQuoteReply.quotableMarkdown(text), "Intro text.\n\n[Artifact: Plan]\n\nOutro.")
        XCTAssertEqual(ChatQuoteReply.quotableMarkdown(":::artifact key=\"k1\" kind=\"code\" title=\"\"\nx\n:::"),
                       "[Artifact: k1]")
    }

    func testSelectedTextIsTheRangeOrNilWhenEmpty() {
        let text = "Keep the retry budget small."
        XCTAssertEqual(ChatQuoteReply.selectedText(text, selection: (text as NSString).range(of: "retry budget")),
                       "retry budget")
        XCTAssertNil(ChatQuoteReply.selectedText(text, selection: NSRange(location: 4, length: 0)))
        XCTAssertNil(ChatQuoteReply.selectedText(text, selection: NSRange(location: 4, length: 1)), "a lone space")
        XCTAssertNil(ChatQuoteReply.selectedText(text, selection: NSRange(location: 20, length: 500)), "out of range")
    }

    func testTheBatchAndTheTypedTextBecomeOneMessage() {
        let quotes = [ChatQuoteDraft(quote: "retry budget", comment: "Why so small?"),
                      ChatQuoteDraft(quote: "Ship on Friday\nwith ops", comment: "")]
        XCTAssertEqual(ChatQuoteReply.compose(quotes: quotes, typed: "And staging? "), """
            About these parts of your answers:

            1. On this passage:
            > retry budget
            Why so small?

            2. On this passage:
            > Ship on Friday
            > with ops

            And staging?
            """)
    }

    func testNoQuotesIsTheTypedTextAndNothingIsNil() {
        XCTAssertEqual(ChatQuoteReply.compose(quotes: [], typed: " hi "), "hi")
        XCTAssertNil(ChatQuoteReply.compose(quotes: [], typed: "  "))
        XCTAssertEqual(ChatQuoteReply.compose(quotes: [ChatQuoteDraft(quote: "x", comment: "")], typed: ""),
                       "About these parts of your answers:\n\n1. On this passage:\n> x")
    }
}

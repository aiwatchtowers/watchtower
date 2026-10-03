import XCTest
@testable import WatchtowerCore

/// "Suggest a change" (spec 2026-10-02 §9.1, §9.2): the reply ends with one
/// fenced block tagged `wt-edit` holding the replacement for the selection;
/// only a complete block counts, and only the first.
final class WtEditBlockTests: XCTestCase {
    func testOneBlockIsTheReplacement() {
        let reply = """
        Rename the variable:

        ```wt-edit
        let total = items.count
        print(total)
        ```
        """
        XCTAssertEqual(WtEditBlock.replacement(in: reply), "let total = items.count\nprint(total)")
    }

    func testNoBlockMeansNoApply() {
        XCTAssertNil(WtEditBlock.replacement(in: "It loads the config.\n\n```swift\nload()\n```\n"))
        XCTAssertNil(WtEditBlock.replacement(in: ""))
    }

    func testTwoBlocksTakeTheFirstOnly() {
        let reply = "a\n```wt-edit\nfirst\n```\nb\n```wt-edit\nsecond\n```\n"
        XCTAssertEqual(WtEditBlock.replacement(in: reply), "first")
    }

    /// While the reply streams, an open block is no suggestion yet.
    func testAnUnterminatedBlockWhileStreamingIsNone() {
        XCTAssertNil(WtEditBlock.replacement(in: "Here:\n```wt-edit\nlet x = 1\nlet y"))
        XCTAssertNil(WtEditBlock.replacement(in: "Here:\n```wt-edit"))
        XCTAssertNil(WtEditBlock.replacement(in: "Here:\n```wt-edit\nlet x = 1\n``"), "a shorter run closes nothing")
    }

    /// A longer fence holds code with backtick runs; only a run at least as
    /// long closes it.
    func testALongerFenceHoldsBackticks() {
        let reply = "````wt-edit\nlet s = \"```\"\n```\nstill code\n````\n"
        XCTAssertEqual(WtEditBlock.replacement(in: reply), "let s = \"```\"\n```\nstill code")
    }

    func testAnEmptyBlockDeletesTheSelection() {
        XCTAssertEqual(WtEditBlock.replacement(in: "Remove it.\n```wt-edit\n```"), "")
    }

    /// The tag is the info string's first word, not a prefix of another.
    func testOnlyTheWtEditTagCounts() {
        XCTAssertNil(WtEditBlock.replacement(in: "```wt-editor\nx\n```"))
        XCTAssertEqual(WtEditBlock.replacement(in: "```wt-edit swift\nx\n```"), "x")
        XCTAssertEqual(WtEditBlock.replacement(in: "  ```wt-edit\nx\n  ```"), "x", "indented up to three spaces")
    }

    func testCRLFRepliesKeepTheirLines() {
        XCTAssertEqual(WtEditBlock.replacement(in: "```wt-edit\r\na\r\nb\r\n```\r\n"), "a\nb")
    }

    /// A fenced block drops the newline before its closing fence; a
    /// selection that ended with a line break gets it back, so Apply never
    /// joins the next line onto the replacement.
    func testFittedKeepsTheSelectionsTrailingLineBreak() {
        XCTAssertEqual(WtEditBlock.fitted("b()", toReplace: "a()\n"), "b()\n")
        XCTAssertEqual(WtEditBlock.fitted("b()", toReplace: "a()\r\n"), "b()\r\n")
        XCTAssertEqual(WtEditBlock.fitted("b()", toReplace: "a()"), "b()")
        XCTAssertEqual(WtEditBlock.fitted("b()\n", toReplace: "a()\n"), "b()\n")
    }
}

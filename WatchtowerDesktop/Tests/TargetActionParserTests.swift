import XCTest
@testable import WatchtowerDesktop

final class TargetActionParserTests: XCTestCase {
    func testNoBlockReturnsTextUnchanged() {
        let r = TargetActionParser.parse("Just a plain answer.")
        XCTAssertEqual(r.text, "Just a plain answer.")
        XCTAssertTrue(r.actions.isEmpty)
        XCTAssertTrue(r.errors.isEmpty)
    }

    func testSingleBlockExtractedAndStripped() {
        let raw = """
        Here is what I'll do:
        ```watchtower-action
        {"type":"update_status","status":"done","reason":"merged"}
        ```
        Done.
        """
        let r = TargetActionParser.parse(raw)
        XCTAssertEqual(r.actions.count, 1)
        XCTAssertEqual(r.actions.first?.type, .updateStatus)
        XCTAssertFalse(r.text.contains("watchtower-action"))
        XCTAssertTrue(r.text.contains("Here is what"))
        XCTAssertTrue(r.text.contains("Done."))
    }

    func testMultipleBlocks() {
        let raw = """
        ```watchtower-action
        {"type":"add_sub_item","text":"a","reason":"r1"}
        ```
        and
        ```watchtower-action
        {"type":"update_progress","progress":50,"reason":"r2"}
        ```
        """
        let r = TargetActionParser.parse(raw)
        XCTAssertEqual(r.actions.count, 2)
        XCTAssertTrue(r.errors.isEmpty)
    }

    func testBrokenJSONBecomesError() {
        let raw = """
        ```watchtower-action
        {"type":"update_status", oops}
        ```
        """
        let r = TargetActionParser.parse(raw)
        XCTAssertTrue(r.actions.isEmpty)
        XCTAssertEqual(r.errors.count, 1)
    }

    func testInvalidActionBecomesError() {
        let raw = """
        ```watchtower-action
        {"type":"update_progress","progress":999,"reason":"x"}
        ```
        """
        let r = TargetActionParser.parse(raw)
        XCTAssertTrue(r.actions.isEmpty)
        XCTAssertEqual(r.errors.count, 1)
    }
}

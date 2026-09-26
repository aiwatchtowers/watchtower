import XCTest
@testable import WatchtowerCore

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

    /// LLMs commonly emit numeric fields as quoted strings. Decode them
    /// leniently instead of failing the whole action.
    func testNumericProgressAsStringDecodes() {
        let raw = """
        ```watchtower-action
        {"type":"update_progress","progress":"50","reason":"r"}
        ```
        """
        let r = TargetActionParser.parse(raw)
        XCTAssertEqual(r.actions.count, 1)
        XCTAssertEqual(r.actions.first?.progress, 50)
        XCTAssertTrue(r.errors.isEmpty)
    }

    func testNumericTargetIdAsStringDecodes() {
        let raw = """
        ```watchtower-action
        {"type":"link_target","target_id":"7","relation":"blocks","reason":"r"}
        ```
        """
        let r = TargetActionParser.parse(raw)
        XCTAssertEqual(r.actions.count, 1)
        XCTAssertEqual(r.actions.first?.targetId, 7)
        XCTAssertTrue(r.errors.isEmpty)
    }

    /// Execute-mode blocks parse like any other and keep the `mode` field so
    /// the apply layer can distinguish directive from proposal.
    func testExecuteModePassesThrough() {
        let raw = """
        ```watchtower-action
        {"type":"update_due_date","due_date":"2026-09-01","reason":"owner directive","mode":"execute"}
        ```
        """
        let r = TargetActionParser.parse(raw)
        XCTAssertEqual(r.actions.count, 1)
        XCTAssertEqual(r.actions.first?.mode, "execute")
        XCTAssertEqual(r.actions.first?.isExecute, true)
        XCTAssertTrue(r.errors.isEmpty)
    }

    /// An unknown action type must surface a specific error naming the field,
    /// not the opaque "malformed action JSON".
    func testUnknownTypeProducesSpecificError() {
        let raw = """
        ```watchtower-action
        {"type":"add_jira_subtask","text":"x","reason":"r"}
        ```
        """
        let r = TargetActionParser.parse(raw)
        XCTAssertTrue(r.actions.isEmpty)
        XCTAssertEqual(r.errors.count, 1)
        XCTAssertTrue(r.errors[0].lowercased().contains("type"))
        XCTAssertNotEqual(r.errors[0], "malformed action JSON")
    }
}

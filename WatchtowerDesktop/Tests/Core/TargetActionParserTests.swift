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

    /// A reply keeps its text on both sides of a tool call, so a block the
    /// assistant repeats after the call is one action, never applied twice.
    func testARepeatedBlockIsOneAction() {
        let block = """
        ```watchtower-action
        {"type":"update_due_date","due_date":"2026-09-01","reason":"first","mode":"execute"}
        ```
        """
        let again = block.replacingOccurrences(of: "first", with: "said again")
        let r = TargetActionParser.parse("Let me check.\n\(block)\n\nDone.\n\(again)")
        XCTAssertEqual(r.actions.count, 1)
        XCTAssertEqual(r.actions.first?.reason, "first")
        XCTAssertTrue(r.errors.isEmpty)
    }

    /// The same change first proposed, then directed: the directive wins.
    func testARepeatedBlockKeepsTheExecuteCopy() {
        let proposed = """
        ```watchtower-action
        {"type":"update_due_date","due_date":"2026-09-01","reason":"maybe"}
        ```
        """
        let directed = proposed.replacingOccurrences(of: "\"reason\":\"maybe\"",
                                                     with: "\"reason\":\"owner said so\",\"mode\":\"execute\"")
        let r = TargetActionParser.parse("\(proposed)\n\(directed)\n\(proposed)")
        XCTAssertEqual(r.actions.count, 1)
        XCTAssertEqual(r.actions.first?.isExecute, true)
    }

    /// TGT-BRIEF-03: a block written before a tool call and revised after
    /// it is one action, the final version; the dropped draft is counted.
    func testARevisedBlockAcrossAToolCallYieldsOnlyTheFinalVersion() {
        let draft = """
        ```watchtower-action
        {"type":"add_sub_item","text":"first draft","mode":"execute","reason":"owner said"}
        ```
        """
        let revised = draft.replacingOccurrences(of: "first draft", with: "checked wording")
        let finalText = "\n\nChecked.\n\(revised)"
        let reply = "Let me look.\n\(draft)" + finalText
        let r = TargetActionParser.parse(reply: reply, finalText: finalText)
        XCTAssertEqual(r.actions.map(\.text), ["checked wording"])
        XCTAssertEqual(r.ignored, 1)
        XCTAssertTrue(r.errors.isEmpty)
        XCTAssertFalse(r.text.contains("watchtower-action"), "every block leaves the visible text")
        XCTAssertTrue(r.text.contains("Let me look."), "the preamble stays visible")
    }

    /// A block the model repeats unchanged after the tool call is kept and
    /// not reported as dropped; a malformed draft before the call is ignored.
    func testABlockRepeatedAfterAToolCallIsNotCountedAsIgnored() {
        let block = """
        ```watchtower-action
        {"type":"update_due_date","due_date":"2026-09-01","reason":"r","mode":"execute"}
        ```
        """
        let broken = "```watchtower-action\n{\"type\":\n```"
        let finalText = "\nDone.\n\(block)"
        let r = TargetActionParser.parse(reply: "\(broken)\n\(block)" + finalText, finalText: finalText)
        XCTAssertEqual(r.actions.count, 1)
        XCTAssertEqual(r.ignored, 0)
        XCTAssertTrue(r.errors.isEmpty, "the pre-tool text is a draft, not a proposal")
    }

    /// A reply with no tool call: the final text is the whole reply.
    func testAReplyWithoutToolsParsesAsBefore() {
        let reply = "Ok.\n```watchtower-action\n{\"type\":\"update_due_date\",\"due_date\":\"2026-09-01\",\"reason\":\"r\"}\n```"
        let r = TargetActionParser.parse(reply: reply, finalText: reply)
        XCTAssertEqual(r.actions.count, 1)
        XCTAssertEqual(r.ignored, 0)
        XCTAssertEqual(r.text, "Ok.")
    }
}

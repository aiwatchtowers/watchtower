import XCTest
@testable import WatchtowerCore

/// The fenced blocks a Discuss thread's agent ends a reply with (spec
/// 2026-11-08 §3), read like Go's shared fixture says.
final class SpecReviewThreadBlocksTests: XCTestCase {
    /// Go's `internal/specreview/testdata/thread_blocks`, read in place.
    private static var fixtureDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/specreview/testdata/thread_blocks")
    }

    private struct Case: Decodable {
        let reply: String
        let question: String?
        let finding: SpecReviewProposedFinding?
    }

    func testFixturesParseLikeGo() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.fixtureDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertGreaterThanOrEqual(files.count, 6)
        for file in files {
            let c = try JSONDecoder().decode(Case.self, from: Data(contentsOf: file))
            let parsed = SpecReviewThreadBlocks.parse(c.reply, final: true)
            let name = file.lastPathComponent
            XCTAssertEqual(parsed.question, c.question, name)
            XCTAssertEqual(parsed.finding, c.finding, name)
            // Every block leaves the shown text, valid or not.
            XCTAssertFalse(parsed.text.contains("```watchtower-"), name)
        }
    }

    func testStreamingHidesOpenBlock() {
        let streaming = "It holds.\n\n```watchtower-ask-author\n{\"question\": \"Was mid"
        let live = SpecReviewThreadBlocks.parse(streaming, final: false)
        XCTAssertEqual(live.text, "It holds.")
        XCTAssertNil(live.question)

        // A closed block is read only once the reply is final.
        let closed = streaming + "night meant?\"}\n```"
        XCTAssertNil(SpecReviewThreadBlocks.parse(closed, final: false).question)
        XCTAssertEqual(SpecReviewThreadBlocks.parse(closed, final: false).text, "It holds.")
        XCTAssertEqual(SpecReviewThreadBlocks.parse(closed, final: true).question, "Was midnight meant?")

        // Once final, an unclosed block stays visible: nothing is read from it.
        let final = SpecReviewThreadBlocks.parse(streaming, final: true)
        XCTAssertTrue(final.text.contains("```watchtower-ask-author"))
        XCTAssertNil(final.question)
    }

    func testPlainReplyUntouched() {
        let text = "The finding holds: see `Behaviour`."
        let parsed = SpecReviewThreadBlocks.parse(text, final: true)
        XCTAssertEqual(parsed.text, text)
        XCTAssertNil(parsed.question)
        XCTAssertNil(parsed.finding)
    }

    func testOtherFencesAndMidLineFencesAreNotBlocks() {
        let text = "See ```watchtower-ask-author inline.\n\n```watchtower-findings\n{}\n```"
        let parsed = SpecReviewThreadBlocks.parse(text, final: true)
        XCTAssertEqual(parsed.text, text)
        XCTAssertNil(parsed.question)
    }

    func testFindingNeedsKnownKindAndQuote() {
        func block(_ json: String) -> SpecReviewProposedFinding? {
            SpecReviewThreadBlocks.parse("x\n\n```watchtower-finding\n\(json)\n```", final: true).finding
        }
        let quote = #""quote": {"source": "document", "text": "Muting lasts a day."}"#
        XCTAssertNotNil(block(#"{"kind": "missing", "title": "T", "text": "X", "# + quote + "}"))
        XCTAssertNil(block(#"{"kind": "agreement", "title": "T", "text": "X", "# + quote + "}"))
        XCTAssertNil(block(#"{"kind": "missing", "title": " ", "text": "X", "# + quote + "}"))
        XCTAssertNil(block(#"{"kind": "missing", "title": "T", "text": "X", "quote": {"source": "web", "text": "a"}}"#))
        XCTAssertNil(block(#"{"kind": "missing", "title": "T", "text": "X"}"#))
    }

    func testQuestionOverGoCapIsNoQuestion() {
        let long = String(repeating: "a", count: SpecReviewThreadBlocks.maxQuestionRunes + 1)
        let text = "x\n\n```watchtower-ask-author\n{\"question\": \"\(long)\"}\n```"
        XCTAssertNil(SpecReviewThreadBlocks.parse(text, final: true).question)
    }
}

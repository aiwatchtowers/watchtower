import XCTest
import GRDB
@testable import WatchtowerCore

/// The drawer's summary of an ask raised from the agent's terminal question
/// (`origin: chat`): the reason line becomes a caption, and the question the
/// card already shows is not repeated in the bubble.
final class OwnerAskSummaryPartsTests: XCTestCase {
    private static let longQuestion = "Extend `ai query --read-folder` from the workbench folder to the registered "
        + "worktrees of this workbench's sessions (terminal_session_worktrees)?"

    private func ask(
        origin: String = "chat",
        kind: String = "question",
        title: String? = nil,
        summary: String,
        questions: [String] = [longQuestion]
    ) throws -> OwnerAsk {
        let items = questions.enumerated().map { index, text in
            ["id": "q\(index + 1)", "question": text, "options": [[String: String]]()] as [String: Any]
        }
        let payload = try XCTUnwrap(String(bytes: try JSONSerialization.data(withJSONObject: ["questions": items]), encoding: .utf8))
        return try OwnerAsk(row: Row([
            "id": 7, "project_id": 1, "level": "full", "origin": origin, "kind": kind,
            "title": title ?? questions.first ?? "t", "summary": summary,
            "payload": payload, "status": "open"
        ]))
    }

    private func parts(_ ask: OwnerAsk) -> OwnerAskPresentation.SummaryParts {
        OwnerAskPresentation.summaryParts(for: ask)
    }

    /// An ask raised before the Go change: the question, then the reason.
    func testOldShapeChatAskKeepsOnlyTheCaption() throws {
        let away = "Asked in the terminal while you were away."
        let result = parts(try ask(summary: Self.longQuestion + "\n" + away))

        XCTAssertEqual(result.body, "", "the question is the card's; no bubble repeats it")
        XCTAssertEqual(result.reason, away)
    }

    func testOldShapeWithAClippedTitle() throws {
        let clipped = String(Self.longQuestion.prefix(119)) + "…"
        let left = "Asked in the terminal; you left the session."
        let result = parts(try ask(title: clipped, summary: Self.longQuestion + "\n" + left))

        XCTAssertEqual(result.body, "")
        XCTAssertEqual(result.reason, left)
    }

    func testNewShapeKeepsTheContextAsTheBody() throws {
        let context = "I found two places that read the folder.\nBoth assume one root."
        let result = parts(try ask(summary: context + "\n\nAsked in the terminal; no answer for 12 min."))

        XCTAssertEqual(result.body, context)
        XCTAssertEqual(result.reason, "Asked in the terminal; no answer for 12 min.")
    }

    func testReasonOnlyHasNoBody() throws {
        let result = parts(try ask(summary: "Asked in the terminal; no answer for 0 min.\n"))

        XCTAssertEqual(result.body, "")
        XCTAssertEqual(result.reason, "Asked in the terminal; no answer for 0 min.")
    }

    /// A context paragraph that is the question again (whitespace aside)
    /// goes; the rest of the context stays.
    func testContextParagraphRepeatingTheQuestionIsDropped() throws {
        let spaced = Self.longQuestion.replacingOccurrences(of: " from ", with: "\n from  ")
        let summary = "Some context.\n\n" + spaced + "\n\nAsked in the terminal while you were away."
        let result = parts(try ask(summary: summary))

        XCTAssertEqual(result.body, "Some context.")
    }

    func testAContextLineRepeatingTheQuestionIsDropped() throws {
        let summary = "Some context.\n" + Self.longQuestion + "\nMore context.\n\nAsked in the terminal while you were away."
        let result = parts(try ask(summary: summary))

        XCTAssertEqual(result.body, "Some context.\nMore context.")
    }

    /// The reason words in another ask's summary are the agent's text.
    func testAgentAskSummaryStaysAsWritten() throws {
        let summary = Self.longQuestion + "\nAsked in the terminal while you were away."
        let result = parts(try ask(origin: "agent", kind: "review", summary: summary))

        XCTAssertEqual(result.body, summary)
        XCTAssertNil(result.reason)
    }

    func testAgentQuestionSummaryRepeatingTheQuestionStays() throws {
        let result = parts(try ask(origin: "agent", summary: Self.longQuestion))

        XCTAssertEqual(result.body, Self.longQuestion, "only a raised ask is deduplicated")
    }

    /// A reason line only counts as the last line, in one of Go's shapes.
    func testOnlyAnExactTrailingReasonLineIsACaption() throws {
        let mid = "Asked in the terminal while you were away.\nThen more."
        XCTAssertEqual(parts(try ask(summary: mid)).body, mid)
        XCTAssertNil(parts(try ask(summary: mid)).reason)

        let odd = "Asked in the terminal; no answer for many min."
        XCTAssertEqual(parts(try ask(summary: odd)).body, odd)
        XCTAssertNil(parts(try ask(summary: odd)).reason)
    }

    func testMultiQuestionChatSummaryOnlyLosesTheReason() throws {
        let summary = "Two things.\n\nAsked in the terminal while you were away."
        let result = parts(try ask(summary: summary, questions: ["First?", "Second?"]))

        XCTAssertEqual(result.body, "Two things.")
        XCTAssertEqual(result.reason, "Asked in the terminal while you were away.")
    }

    func testEmptySummary() throws {
        let result = parts(try ask(summary: ""))

        XCTAssertEqual(result.body, "")
        XCTAssertNil(result.reason)
    }
}

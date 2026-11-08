import XCTest
@testable import WatchtowerCore

/// `SpecReviewAnswer` and the next author loop (spec 2026-11-08 §1, §3):
/// every findings comment names its finding (`item_key`), so Go seeds that
/// finding, not an owner comment; a finding added from a Discuss thread
/// goes out like a reviewer's.
final class SpecReviewAnswerTests: XCTestCase {
    private let snapshot = "# Title\nIntro text\n## Behaviour\nMuting lasts twenty-four hours\nMore\n"

    private func result() throws -> SpecReviewResult {
        let end = snapshot.utf8.count
        return try JSONDecoder().decode(SpecReviewResult.self, from: Data("""
        {"summary":"s","chapters":[{"key":"ch:0","heading":"Title","start":0,"end":19},
        {"key":"ch:1","heading":"Behaviour","start":19,"end":\(end)}],
        "agreements":[{"key":"ag:1","text":"Mute is per channel","status":"differs","chapter":"ch:1"}],
        "decided_alone":[{"key":"da:1","text":"Local db","chapter":"ch:0"}]}
        """.utf8))
    }

    private func threadFinding() throws -> SpecReviewProposedFinding {
        var finding = try XCTUnwrap(SpecReviewThreadBlocks.decodeFinding(Data("""
        {"kind":"missing","severity":"major","title":"Ends at midnight","text":"Say when a mute ends",
         "quote":{"source":"document","text":"Muting lasts"},"where":{"heading":"Behaviour","quote":"Muting lasts twenty-four hours"}}
        """.utf8)))
        finding.key = "tf:0123456789ab"
        finding.chapter = "ch:1"
        return finding
    }

    func testCommentsCarryItemKey() throws {
        let marks = [
            "ag:1": SpecReviewMark(key: "ag:1", state: .comment),
            "da:1": SpecReviewMark(key: "da:1", state: .comment, body: "ask first"),
            "ag:gone": SpecReviewMark(key: "ag:gone", state: .comment, about: "Threads stay muted"),
            "ck:ok": SpecReviewMark(key: "ck:ok", state: .ok)
        ]
        let a = SpecReviewAnswer.build(result: try result(), marks: marks, base: OwnerAskAnswer(comments: [
            .init(anchor: CommentAnchor(quote: "Intro text", prefix: "", suffix: "", heading: "Title"), body: "margin")
        ]), verdict: .changes, snapshot: snapshot)
        XCTAssertEqual(a.comments.map(\.body), [
            "margin", "Mute is per channel", "Local db — ask first", "From the previous run: Threads stay muted"
        ])
        XCTAssertEqual(a.comments.map(\.itemKey), [nil, "ag:1", "da:1", "ag:gone"],
                       "a Fix with or without words names its finding; a margin comment none")
        let encoded = try a.encoded()
        XCTAssertTrue(encoded.contains(#""item_key":"ag:1""#), encoded)
        XCTAssertEqual(encoded.components(separatedBy: "item_key").count - 1, 3, "omitted on the margin comment")

        let loop = try JSONDecoder().decode([SpecReviewLedgerEntry].self, from: Data("""
        [{"key":"bs:2","text":"No undo","reply":{"reply":"disagree","note":"no"},"verdict":"disputed","settled":2}]
        """.utf8))
        let looped = SpecReviewAnswer.build(result: nil, marks: ["bs:2": SpecReviewMark(key: "bs:2", state: .comment)],
                                            loop: loop, verdict: .approved, snapshot: snapshot)
        XCTAssertEqual(looped.comments.map(\.itemKey), ["bs:2"])
    }

    /// A Fix on a finding added from a thread goes out like a reviewer's —
    /// its own words and anchor, its key — never as "From the previous run".
    func testThreadFindingFixSent() throws {
        let finding = try threadFinding()
        let marks = [
            finding.key: SpecReviewMark(key: finding.key, state: .comment, body: "by Friday"),
            "ag:1": SpecReviewMark(key: "ag:1", state: .comment)
        ]
        let a = SpecReviewAnswer.build(result: try result(), marks: marks, threadFindings: [finding],
                                       verdict: .changes, snapshot: snapshot)
        XCTAssertEqual(a.comments.map(\.body), [
            "Mute is per channel", "Ends at midnight: Say when a mute ends — by Friday"
        ])
        let sent = try XCTUnwrap(a.comments.last)
        XCTAssertEqual(sent.itemKey, finding.key)
        XCTAssertEqual(sent.heading, "Behaviour")
        XCTAssertEqual(sent.quote, "Muting lasts twenty-four hours")
        XCTAssertTrue(SpecReviewAnswer.orphanMarks(result: try result(), marks: marks, threadFindings: [finding]).isEmpty)

        // No reviewer result (a re-run queued): still its own comment.
        let queued = SpecReviewAnswer.build(result: nil, marks: [finding.key: try XCTUnwrap(marks[finding.key])],
                                            threadFindings: [finding], verdict: .changes, snapshot: snapshot)
        XCTAssertEqual(queued.comments.map(\.body), ["Ends at midnight: Say when a mute ends — by Friday"])
    }
}

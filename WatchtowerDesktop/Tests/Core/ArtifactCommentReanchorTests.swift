import XCTest
@testable import WatchtowerCore

final class ArtifactCommentReanchorTests: XCTestCase {
    private let v1 = "Keep the retry budget small.\n\nShip on Friday."

    private func comment(
        _ id: Int64, quote: String, in text: String, version: Int = 1, status: ArtifactComment.Status = .open
    ) throws -> ArtifactComment {
        let anchor = CommentAnchor.make(text: text, range: try XCTUnwrap(text.range(of: quote)), headings: [])
        return ArtifactComment(
            id: id, conversationID: 1, artifactKey: "plan", artifactVersion: version, body: "b",
            anchorQuote: anchor.quote, anchorPrefix: anchor.prefix, anchorSuffix: anchor.suffix,
            anchorHeading: anchor.heading, status: status, createdAt: 0, sentAt: status == .open ? nil : 1
        )
    }

    func testAPassageKeptOnANewerVersionMovesOntoIt() throws {
        let v2 = "A new intro.\n\n" + v1
        let plan = ArtifactCommentReanchor.plan([try comment(1, quote: "retry budget", in: v1)], text: v2, version: 2)
        XCTAssertEqual(plan.moved, [1])
        XCTAssertEqual(plan.lost, [])
        XCTAssertEqual(plan.ranges[1], (v2 as NSString).range(of: "retry budget"))
    }

    func testFoundOnItsOwnVersionIsANoOp() throws {
        let plan = ArtifactCommentReanchor.plan([try comment(1, quote: "retry budget", in: v1)], text: v1, version: 1)
        XCTAssertTrue(plan.isNoOp)
        XCTAssertNotNil(plan.ranges[1])
    }

    func testOpenAndSentCommentsWhoseQuoteIsGoneAreLost() throws {
        let comments = [try comment(1, quote: "retry budget", in: v1),
                        try comment(2, quote: "Ship on Friday", in: v1, status: .sent)]
        let plan = ArtifactCommentReanchor.plan(comments, text: "Everything was rewritten.", version: 2)
        XCTAssertEqual(plan.lost, [1, 2])
        XCTAssertEqual(plan.moved, [])
        XCTAssertTrue(plan.ranges.isEmpty)
    }

    func testResolvedCommentsOnlyGetAHighlightAndOutdatedOnesAreNeverRelocated() throws {
        let v2 = "A new intro.\n\n" + v1
        let comments = [try comment(1, quote: "retry budget", in: v1, status: .resolved),
                        try comment(2, quote: "Ship on Friday", in: v1, status: .outdated),
                        try comment(3, quote: "Keep the", in: v1, status: .resolved)]
        let kept = ArtifactCommentReanchor.plan(comments, text: v2, version: 2)
        XCTAssertTrue(kept.isNoOp, "resolved/outdated comments never change")
        XCTAssertNotNil(kept.ranges[1])
        XCTAssertNil(kept.ranges[2], "an outdated comment is not re-attached even though its text is back")
        let gone = ArtifactCommentReanchor.plan(comments, text: "Rewritten.", version: 3)
        XCTAssertTrue(gone.isNoOp)
        XCTAssertTrue(gone.ranges.isEmpty)
    }
}

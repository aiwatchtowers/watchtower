import XCTest
@testable import WatchtowerCore

final class ArtifactCommentMessageTests: XCTestCase {
    private func comment(_ id: Int64, quote: String, heading: String, body: String) -> ArtifactComment {
        ArtifactComment(
            id: id, conversationID: 1, artifactKey: "q3-plan", artifactVersion: 2, body: body,
            anchorQuote: quote, anchorPrefix: "", anchorSuffix: "", anchorHeading: heading,
            status: .open, createdAt: 0, sentAt: nil
        )
    }

    func testComposesOneMessageWithEveryQuoteAndCommentInOrder() {
        let text = ArtifactCommentMessage.compose(title: "Q3 plan", key: "q3-plan", version: 2, comments: [
            comment(1, quote: "retry budget small", heading: "Risks", body: "Why so small?"),
            comment(2, quote: "Ship on Friday.\n\nOwners: ops", heading: "", body: "Thursday?")
        ])
        XCTAssertEqual(text, """
            Comments on the artifact "Q3 plan" (key="q3-plan", version 2):

            1. Under "Risks":
            > retry budget small
            Why so small?

            2. On this passage:
            > Ship on Friday.
            >
            > Owners: ops
            Thursday?

            Please reply with a new version of this artifact under the same key that addresses these comments.
            """)
    }

    func testAnUntitledArtifactIsNamedByItsKey() {
        let text = ArtifactCommentMessage.compose(title: "  ", key: "q3-plan", version: 1,
                                                  comments: [comment(1, quote: "x", heading: "", body: "y")])
        XCTAssertTrue(text?.hasPrefix(#"Comments on the artifact "q3-plan" (key="q3-plan", version 1):"#) == true)
    }

    func testNothingToSendComposesNothing() {
        XCTAssertNil(ArtifactCommentMessage.compose(title: "Plan", key: "plan", version: 1, comments: []))
    }

}

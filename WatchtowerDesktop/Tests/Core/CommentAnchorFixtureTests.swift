import Foundation
import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The shared review-anchor fixture (mobile POC spec §6.2): the phone
/// builds review comment anchors with a port of `CommentAnchor`, and the
/// Kit's `CommentAnchorBuilderTests` run the same file — so every case here
/// is what Core makes of it, rendering included.
final class CommentAnchorFixtureTests: XCTestCase {
    func testTheFixtureCoversTheFourPlannedCases() throws {
        let fixtures = try CommentAnchorFixtures.load()
        XCTAssertEqual(fixtures.contextLength, CommentAnchor.contextLength)
        XCTAssertEqual(fixtures.cases.map(\.name), [
            "selection_at_document_start",
            "selection_at_document_end",
            "selection_spanning_a_heading",
            "selection_in_a_clipped_snapshots_last_shown_line"
        ])
        XCTAssertEqual(fixtures.cases.filter(\.docClipped).count, 1)
        // A full window counted in characters, not scalars or UTF-16 units:
        // a port that counts anything else fails this case.
        XCTAssertTrue(fixtures.cases.contains { fixture in
            let prefix = fixture.anchor.prefix
            return prefix.count == CommentAnchor.contextLength && prefix.unicodeScalars.count > prefix.count
        }, "a multi-scalar grapheme inside a full context window")
    }

    func testCoreRendersEachCasesSnapshotToItsText() throws {
        for fixture in try CommentAnchorFixtures.load().cases {
            let doc = DocumentRendering.render(fixture.markdown)
            XCTAssertEqual(doc.text, fixture.text, fixture.name)
            XCTAssertEqual(
                doc.headings.map { CommentAnchorFixtures.Heading(offset: $0.offset, title: $0.title) },
                fixture.headings, fixture.name
            )
        }
    }

    func testCoreMakesEachCasesAnchorAndLocatesItAgain() throws {
        for fixture in try CommentAnchorFixtures.load().cases {
            let doc = DocumentRendering.render(fixture.markdown)
            let selection = NSRange(location: fixture.selection.location, length: fixture.selection.length)
            let anchor = try XCTUnwrap(OwnerAskReviewText.anchor(selection: selection, in: doc), fixture.name)
            XCTAssertEqual(
                CommentAnchorFixtures.Anchor(
                    quote: anchor.quote, prefix: anchor.prefix, suffix: anchor.suffix, heading: anchor.heading
                ),
                fixture.anchor, fixture.name
            )
            XCTAssertEqual(OwnerAskReviewText.range(of: anchor, in: doc), selection, "\(fixture.name): round trip")
        }
    }
}

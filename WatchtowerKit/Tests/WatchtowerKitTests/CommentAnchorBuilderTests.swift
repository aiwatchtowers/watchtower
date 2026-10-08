/// The phone's review anchors (mobile POC spec §6.2): `PlainTextRendering`
/// renders a review ask's `doc_snapshot` to the plain text Core's
/// `DocumentRendering` gives, and `CommentAnchorBuilder` makes Core's
/// `CommentAnchor` of a selection on it. Every case of the shared
/// `Fixtures/asks/anchor-fixtures.json` (Core's `CommentAnchorFixtureTests`
/// runs the same file) must come out equal.
import Foundation
import WatchtowerKit
import XCTest

final class CommentAnchorBuilderTests: XCTestCase {
    private struct Fixtures: Decodable {
        struct Heading: Decodable, Equatable {
            let offset: Int
            let title: String
        }

        struct Selection: Decodable {
            let location: Int
            let length: Int
        }

        struct Anchor: Decodable, Equatable {
            let quote: String
            let prefix: String
            let suffix: String
            let heading: String
        }

        struct Case: Decodable {
            let name: String
            let markdown: String
            let text: String
            let headings: [Heading]
            let selection: Selection
            let anchor: Anchor
        }

        let contextLength: Int
        let cases: [Case]

        enum CodingKeys: String, CodingKey {
            case contextLength = "context_length"
            case cases
        }
    }

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // WatchtowerKitTests
        .deletingLastPathComponent() // Tests
        .appendingPathComponent("Fixtures/asks/anchor-fixtures.json")

    private func load() throws -> Fixtures {
        try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: Self.fixtureURL))
    }

    // MARK: - The shared fixture

    func testTheContextLengthIsCores() throws {
        XCTAssertEqual(try load().contextLength, CommentAnchorBuilder.contextLength)
        XCTAssertEqual(try load().cases.count, 4)
    }

    func testEachCasesSnapshotRendersToItsTextAndHeadings() throws {
        for fixture in try load().cases {
            let document = PlainTextRendering.render(fixture.markdown)
            XCTAssertEqual(document.text, fixture.text, fixture.name)
            XCTAssertEqual(
                document.headings.map { Fixtures.Heading(offset: $0.offset, title: $0.title) },
                fixture.headings,
                fixture.name
            )
        }
    }

    func testEachCasesSelectionMakesItsAnchor() throws {
        for fixture in try load().cases {
            let document = PlainTextDocument(
                text: fixture.text,
                headings: fixture.headings.map { .init(offset: $0.offset, level: 1, title: $0.title) }
            )
            let selection = NSRange(location: fixture.selection.location, length: fixture.selection.length)
            let anchor = try XCTUnwrap(CommentAnchorBuilder.anchor(selection: selection, in: document), fixture.name)
            XCTAssertEqual(
                Fixtures.Anchor(quote: anchor.quote, prefix: anchor.prefix, suffix: anchor.suffix, heading: anchor.heading),
                fixture.anchor,
                fixture.name
            )
        }
    }

    func testAnEmptyOrOutOfRangeSelectionMakesNoAnchor() {
        let document = PlainTextRendering.render("Hello acme.\n")
        XCTAssertNil(CommentAnchorBuilder.anchor(selection: NSRange(location: 2, length: 0), in: document))
        XCTAssertNil(CommentAnchorBuilder.anchor(selection: NSRange(location: 5, length: 400), in: document))
    }

    func testAnAnchorBecomesAnAnswerComment() throws {
        let document = PlainTextRendering.render("## Plan\n\nShip it.\n")
        let anchor = try XCTUnwrap(CommentAnchorBuilder.anchor(selection: NSRange(location: 6, length: 4), in: document))
        XCTAssertEqual(
            OwnerAskAnswer.Comment(anchor: anchor, body: "Why?"),
            OwnerAskAnswer.Comment(quote: "Ship", prefix: "Plan\n\n", suffix: " it.\n\n", heading: "Plan", body: "Why?")
        )
    }

    // MARK: - The rest of the rendering (Core's DocumentRendering rules)

    func testInlineMarkupLeavesOnlyItsText() {
        let document = PlainTextRendering.render(
            "Some **bold**, *em*, _em_, ~~gone~~, `code *x*` and [a link](https://example.com) plus ![img](a.png).\n"
        )
        XCTAssertEqual(document.text, "Some bold, em, em, gone, code *x* and a link plus img.\n\n")
    }

    func testIntrawordUnderscoresAndLoneStarsStay() {
        XCTAssertEqual(PlainTextRendering.render("snake_case_name and 2 * 3\n").text, "snake_case_name and 2 * 3\n\n")
    }

    func testEscapesAndEntitiesAreDecoded() {
        XCTAssertEqual(PlainTextRendering.render("\\*not em\\* &amp; &lt;tag&gt; &#65;\n").text, "*not em* & <tag> A\n\n")
    }

    func testSoftBreaksAreSpacesAndHardBreaksNewlines() {
        XCTAssertEqual(PlainTextRendering.render("one\ntwo  \nthree\\\nfour\n").text, "one two\nthree\nfour\n\n")
    }

    func testListsCarryTheirMarkersAndNesting() {
        let markdown = "- one\n- two\n  - nested\n\n3. three\n4. four\n\n- [x] done\n- [ ] open\n"
        XCTAssertEqual(
            PlainTextRendering.render(markdown).text,
            "• one\n• two\n    • nested\n\n3. three\n4. four\n\n☑ done\n☐ open\n\n"
        )
    }

    func testCodeBlocksQuotesAndRules() {
        let markdown = "```swift\nlet a = 1\n```\n\n> quoted\n> text\n\n---\n\nafter\n"
        XCTAssertEqual(PlainTextRendering.render(markdown).text, "let a = 1\n\nquoted text\n\n\u{00A0}\n\nafter\n\n")
    }

    func testHeadingsKeepUTF16OffsetsAndLevels() {
        let document = PlainTextRendering.render("# Café 👍🏽\n\ntext\n\n### Deep ##\n")
        XCTAssertEqual(document.text, "Café 👍🏽\n\ntext\n\nDeep\n\n")
        XCTAssertEqual(document.headings, [
            .init(offset: 0, level: 1, title: "Café 👍🏽"),
            .init(offset: 17, level: 3, title: "Deep")
        ])
    }

    func testSetextHeadings() {
        let document = PlainTextRendering.render("Title\n=====\n\nSub\n---\n")
        XCTAssertEqual(document.text, "Title\n\nSub\n\n")
        XCTAssertEqual(document.headings.map(\.level), [1, 2])
    }

    func testTablesPutEveryCellOnItsOwnLine() {
        let markdown = "| a | b |\n|---|:-:|\n| 1 | **2** |\n| 3 |\n"
        XCTAssertEqual(PlainTextRendering.render(markdown).text, "a\nb\n1\n2\n3\n\n\n")
    }

    func testAnEmptySnapshotRendersNothing() {
        XCTAssertEqual(PlainTextRendering.render(""), PlainTextDocument(text: "", headings: []))
    }
}

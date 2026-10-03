import XCTest
@testable import WatchtowerCore

final class OwnerAskSnapshotDiffTests: XCTestCase {
    func testIdenticalSnapshotsHaveNoChanges() {
        let text = "# Plan\n\nStep one.\n\n## Rollout\n\nAll at once."
        let diff = OwnerAskSnapshotDiff(previous: text, current: text)
        XCTAssertTrue(diff.isIdentical)
        XCTAssertTrue(diff.addedHeadings.isEmpty)
        XCTAssertTrue(diff.removedHeadings.isEmpty)
        XCTAssertTrue(diff.changedHeadings.isEmpty)
        XCTAssertEqual(diff.lines.count, 7)
    }

    func testAddedRemovedAndChangedHeadingsAreListed() {
        let previous = """
            # Plan
            Intro.
            ## Rollout
            All at once.
            ## Risks
            None.
            ## Notes
            Keep.
            """
        let current = """
            # Plan
            Intro.
            ## Rollout
            In batches of 500.
            ## Notes
            Keep.
            ## Testing
            Smoke test.
            """
        let diff = OwnerAskSnapshotDiff(previous: previous, current: current)
        XCTAssertFalse(diff.isIdentical)
        XCTAssertEqual(diff.addedHeadings, ["Testing"])
        XCTAssertEqual(diff.removedHeadings, ["Risks"])
        XCTAssertEqual(diff.changedHeadings, ["Rollout"])
        XCTAssertEqual(diff.lines.filter { if case .removed = $0 { true } else { false } },
                       [.removed("All at once."), .removed("## Risks"), .removed("None.")])
        XCTAssertEqual(diff.lines.filter { if case .added = $0 { true } else { false } },
                       [.added("In batches of 500."), .added("## Testing"), .added("Smoke test.")])
        XCTAssertEqual(Array(diff.lines.prefix(3)), [.same("# Plan"), .same("Intro."), .same("## Rollout")])
    }

    func testTheLinesReadInDocumentOrder() {
        let diff = OwnerAskSnapshotDiff(previous: "a\nb\nc", current: "a\nB\nc\nd")
        XCTAssertEqual(diff.lines, [.same("a"), .removed("b"), .added("B"), .same("c"), .added("d")])
    }

    func testHeadingsInsideCodeFencesAndHashtagsAreNotSections() {
        let previous = "## Setup\n```sh\n# install\nmake\n```\n#tag"
        let current = "## Setup\n```sh\n# install it\nmake\n```\n#tag"
        let diff = OwnerAskSnapshotDiff(previous: previous, current: current)
        XCTAssertEqual(diff.changedHeadings, ["Setup"], "the fenced comment is body text of Setup")
        XCTAssertTrue(diff.addedHeadings.isEmpty)
        XCTAssertTrue(diff.removedHeadings.isEmpty)
    }

    /// A ``` fence is not closed by ~~~ (nor by a shorter run): a `# line`
    /// inside it stays code, so no heading is added or removed.
    func testAFenceClosesOnlyOnItsOwnKindAndLength() {
        let previous = "## Setup\n```\n~~~\n# one\n```\n## After\nx"
        let current = "## Setup\n```\n~~~\n# two\n```\n## After\nx"
        let diff = OwnerAskSnapshotDiff(previous: previous, current: current)
        XCTAssertEqual(diff.changedHeadings, ["Setup"])
        XCTAssertTrue(diff.addedHeadings.isEmpty, "~~~ does not close a ``` fence: `# two` is code")
        XCTAssertTrue(diff.removedHeadings.isEmpty)

        let longer = OwnerAskSnapshotDiff(previous: "````\n```\n# a\n````\n# Real", current: "````\n```\n# b\n````\n# Real")
        XCTAssertTrue(longer.addedHeadings.isEmpty, "a shorter run does not close a four-backtick fence")
        XCTAssertTrue(longer.changedHeadings.isEmpty, "the change is before the first heading")
    }

    func testAnIndentedHashLineIsCodeNotAHeading() {
        let diff = OwnerAskSnapshotDiff(previous: "## Shell\n    # old", current: "## Shell\n    # new\n\t# tab\n   # Three")
        XCTAssertEqual(diff.changedHeadings, ["Shell"], "four spaces or a tab make a code line in Shell's body")
        XCTAssertEqual(diff.addedHeadings, ["Three"], "up to three spaces is still a heading")
    }

    func testRepeatedHeadingsAreToldApartAndClosingHashesDropped() {
        let previous = "## Notes ##\none\n## Notes\ntwo\n## C#\nx"
        let current = "## Notes\none\n## Notes\nthree\n## C#\nx"
        let diff = OwnerAskSnapshotDiff(previous: previous, current: current)
        XCTAssertEqual(diff.changedHeadings, ["Notes"], "only the second Notes changed")
        XCTAssertTrue(diff.addedHeadings.isEmpty, "`## Notes ##` and `## Notes` are one heading; `C#` keeps its hash")
        XCTAssertTrue(diff.removedHeadings.isEmpty)
    }

    func testAnEmptyPreviousSnapshotAddsEverything() {
        let diff = OwnerAskSnapshotDiff(previous: "", current: "# New\ntext")
        XCTAssertEqual(diff.lines, [.added("# New"), .added("text")])
        XCTAssertEqual(diff.addedHeadings, ["New"])
    }
}

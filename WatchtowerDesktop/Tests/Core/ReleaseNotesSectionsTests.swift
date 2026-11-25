import XCTest
@testable import WatchtowerCore

/// The Software Update window's category badges read the notes `/release`
/// writes; anything else falls back to plain Markdown.
final class ReleaseNotesSectionsTests: XCTestCase {
    private typealias Notes = ReleaseNotesSections

    func testCategorisedNotesSplitIntoSectionsInOrder() throws {
        let notes = """
        ## What's New

        ### ✨ New
        - Inbox folders. (Mac)

        ### 🐞 Fixed
        - The tray icon no longer flickers after sleep.
        - Sync resumes after a network drop.

        **Full Changelog**: v0.1.0...v0.2.0
        """
        let parsed = try XCTUnwrap(Notes.parse(notes))
        XCTAssertEqual(parsed.leading, "")
        XCTAssertEqual(parsed.sections, [
            .init(category: .new, body: "- Inbox folders. (Mac)"),
            .init(category: .fixed, body: "- The tray icon no longer flickers after sleep.\n- Sync resumes after a network drop.")
        ])
        XCTAssertEqual(parsed.trailing, "**Full Changelog**: v0.1.0...v0.2.0")
    }

    func testEveryHeadingMapsToItsCategoryWhateverTheEmojiOrCase() throws {
        let notes = """
        ### ⚠️ Requirements
        - a
        ### ✨ NEW
        - b
        ### ➕ Extended
        - c
        ### 💅 improved
        - d
        ### 🔀 Changed
        - e
        ### 🗑 Removed
        - f
        ### 🔒 Security
        - g
        ### Fixed
        - h
        """
        let parsed = try XCTUnwrap(Notes.parse(notes))
        XCTAssertEqual(parsed.sections.map(\.category), ReleaseNotesCategory.allCases)
        XCTAssertEqual(parsed.sections.map(\.body), ["- a", "- b", "- c", "- d", "- e", "- f", "- g", "- h"])
    }

    func testEmptySectionsAreDropped() throws {
        let parsed = try XCTUnwrap(Notes.parse("### ✨ New\n\n### 🐞 Fixed\n- A.\n### 🔒 Security\n"))
        XCTAssertEqual(parsed.sections, [.init(category: .fixed, body: "- A.")])
        XCTAssertNil(Notes.parse("### ✨ New\n### 🐞 Fixed\n\n**Full Changelog**: v0.1.0...v0.1.1"))
    }

    func testUnknownHeadingAmongCategoriesFallsBack() {
        XCTAssertNil(Notes.parse("### 💅 Improved\n- A.\n### 🐞 Fixes\n- B."))
        XCTAssertNil(Notes.parse("### ✨ New\n- A.\n### Notes for admins\n- B."))
    }

    func testLevelTwoHeadingEndsTheSections() throws {
        let parsed = try XCTUnwrap(Notes.parse("### 🐞 Fixed\n- A.\n\n## Downloads\n- Mac app"))
        XCTAssertEqual(parsed.sections, [.init(category: .fixed, body: "- A.")])
        XCTAssertEqual(parsed.trailing, "## Downloads\n- Mac app")
    }

    func testNotesWithoutCategoryHeadingsFallBack() {
        XCTAssertNil(Notes.parse(""))
        XCTAssertNil(Notes.parse("## What's New"))
        XCTAssertNil(Notes.parse("## What's New\n\n### Features\n- A thing.\n\n### Bug Fixes\n- Another."))
        XCTAssertNil(Notes.parse("Just a paragraph."))
        XCTAssertNil(Notes.parse("## New\n#### Fixed\n- x"))
    }

    func testTextBeforeTheCategoriesIsKept() throws {
        let notes = """
        ## What’s New

        ### Highlights
        A big one.

        ### ✨ New
        - Inbox folders.
          Folders sync to the phone.
        """
        let parsed = try XCTUnwrap(Notes.parse(notes))
        XCTAssertEqual(parsed.leading, "### Highlights\nA big one.")
        XCTAssertEqual(parsed.sections, [.init(
            category: .new,
            body: "- Inbox folders.\n  Folders sync to the phone."
        )])
        XCTAssertEqual(parsed.trailing, "")
    }

    func testCRLFNotesAreParsed() throws {
        let parsed = try XCTUnwrap(Notes.parse("## What's New\r\n\r\n### ✨ New\r\n- Inbox folders.\r\n\r\n**Full Changelog**: v0.1.0...v0.2.0"))
        XCTAssertEqual(parsed.sections, [.init(category: .new, body: "- Inbox folders.")])
        XCTAssertEqual(parsed.trailing, "**Full Changelog**: v0.1.0...v0.2.0")
    }

    func testLastSectionKeepsEverythingUpToTheChangelogLine() throws {
        let notes = """
        ### 🐞 Fixed
        - A.
          continued.
        * B.
        + C.
        1. An ordered item.
        A closing sentence.

        **Full Changelog**: v0.1.0...v0.2.0
        """
        let parsed = try XCTUnwrap(Notes.parse(notes))
        XCTAssertEqual(parsed.sections, [.init(
            category: .fixed,
            body: "- A.\n  continued.\n* B.\n+ C.\n1. An ordered item.\nA closing sentence."
        )])
        XCTAssertEqual(parsed.trailing, "**Full Changelog**: v0.1.0...v0.2.0")
    }

    func testHeadingsInsideCodeBlocksAreText() throws {
        let notes = "### ✨ New\n- Example:\n```\n### Fixed\n**Full Changelog**\n```\n- After."
        let parsed = try XCTUnwrap(Notes.parse(notes))
        XCTAssertEqual(parsed.sections, [.init(
            category: .new,
            body: "- Example:\n```\n### Fixed\n**Full Changelog**\n```\n- After."
        )])
        XCTAssertEqual(parsed.trailing, "")
        XCTAssertNil(Notes.parse("```\n### Fixed\n```"))
    }

    func testEmptyLastSectionStillHandsOverTheChangelogLine() throws {
        let parsed = try XCTUnwrap(Notes.parse("### ✨ New\n- A.\n### 🔒 Security\n**Full Changelog**: v0.1.0...v0.1.1"))
        XCTAssertEqual(parsed.sections, [.init(category: .new, body: "- A.")])
        XCTAssertEqual(parsed.trailing, "**Full Changelog**: v0.1.0...v0.1.1")
    }

    func testCategoryTitles() {
        XCTAssertEqual(ReleaseNotesCategory.allCases.map(\.title),
                       ["Requirements", "New", "Extended", "Improved", "Changed", "Removed", "Security", "Fixed"])
    }
}

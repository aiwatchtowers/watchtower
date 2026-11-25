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
        ### ✨ NEW
        ### ➕ Extended
        ### 💅 improved
        ### 🔀 Changed
        ### 🗑 Removed
        ### 🔒 Security
        ### Fixed
        """
        let parsed = try XCTUnwrap(Notes.parse(notes))
        XCTAssertEqual(parsed.sections.map(\.category), ReleaseNotesCategory.allCases)
        XCTAssertTrue(parsed.sections.allSatisfy { $0.body.isEmpty })
    }

    func testNotesWithoutCategoryHeadingsFallBack() {
        XCTAssertNil(Notes.parse(""))
        XCTAssertNil(Notes.parse("## What's New"))
        XCTAssertNil(Notes.parse("## What's New\n\n### Features\n- A thing.\n\n### Bug Fixes\n- Another."))
        XCTAssertNil(Notes.parse("Just a paragraph."))
        XCTAssertNil(Notes.parse("## New\n#### Fixed\n- x"))
    }

    func testUnknownHeadingsAndTextAreKept() throws {
        let notes = """
        ## What’s New

        ### Highlights
        A big one.

        ### ✨ New
        - Inbox folders.
          Folders sync to the phone.
        ### Notes for admins
        - A policy key.
        """
        let parsed = try XCTUnwrap(Notes.parse(notes))
        XCTAssertEqual(parsed.leading, "### Highlights\nA big one.")
        XCTAssertEqual(parsed.sections, [.init(
            category: .new,
            body: "- Inbox folders.\n  Folders sync to the phone.\n### Notes for admins\n- A policy key."
        )])
        XCTAssertEqual(parsed.trailing, "")
    }

    func testEmptyLastSectionStillHandsOverTheChangelogLine() throws {
        let parsed = try XCTUnwrap(Notes.parse("### 🔒 Security\n\n**Full Changelog**: v0.1.0...v0.1.1"))
        XCTAssertEqual(parsed.sections, [.init(category: .security, body: "")])
        XCTAssertEqual(parsed.trailing, "**Full Changelog**: v0.1.0...v0.1.1")
    }

    func testCategoryTitles() {
        XCTAssertEqual(ReleaseNotesCategory.allCases.map(\.title),
                       ["Requirements", "New", "Extended", "Improved", "Changed", "Removed", "Security", "Fixed"])
    }
}

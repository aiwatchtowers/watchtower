import XCTest
@testable import WatchtowerCore

@MainActor
final class RecipeBufferModelTests: XCTestCase {
    private let recipe = "---\nname: Digest\n---\n\nReads mail.\n\n```js\nlog(\"hi\")\n```\n"

    func testDirtyAfterEdit() {
        let buffer = RecipeBufferModel(automationID: 7, text: recipe, contentHash: "h1")
        XCTAssertFalse(buffer.isDirty)
        XCTAssertEqual(buffer.revision, 1)

        buffer.pageSent(text: recipe + "\n", base: buffer.revision)
        XCTAssertTrue(buffer.isDirty)
        XCTAssertEqual(buffer.text, recipe + "\n")
        XCTAssertEqual(buffer.baseContentHash, "h1")

        buffer.pageSent(text: recipe, base: buffer.revision)
        XCTAssertFalse(buffer.isDirty, "typing back to the loaded text is clean")
    }

    func testResetClearsDirty() {
        let buffer = RecipeBufferModel(automationID: 7, text: recipe, contentHash: "h1")
        buffer.pageSent(text: "edited", base: 1)
        XCTAssertTrue(buffer.isDirty)

        buffer.reset(text: "saved", contentHash: "h2")
        XCTAssertFalse(buffer.isDirty)
        XCTAssertEqual(buffer.text, "saved")
        XCTAssertEqual(buffer.baseContentHash, "h2")
        XCTAssertEqual(buffer.revision, 2, "a reset is a new revision for the page")
    }

    /// An edit typed before a reset reached the page carries the old base:
    /// it is kept (never dropped), and it stays tied to the file it was typed
    /// on, so a save names that file's hash and is refused if the file moved on.
    func testEditOnOlderBaseIsKept() {
        let buffer = RecipeBufferModel(automationID: 7, text: recipe, contentHash: "h1")
        buffer.reset(text: "changed on disk", contentHash: "h2")

        buffer.pageSent(text: "typed before the reload", base: 1)
        XCTAssertEqual(buffer.text, "typed before the reload")
        XCTAssertTrue(buffer.isDirty)
        XCTAssertEqual(buffer.baseContentHash, "h1")

        // Still the old base: still kept, still tied to the old file.
        buffer.pageSent(text: "typed before the reload, more", base: 1)
        XCTAssertEqual(buffer.text, "typed before the reload, more")
        XCTAssertEqual(buffer.baseContentHash, "h1")

        // A reset the page then takes ties later edits to the new file.
        buffer.reset(text: "reloaded", contentHash: "h3")
        buffer.pageSent(text: "reloaded!", base: buffer.revision)
        XCTAssertEqual(buffer.baseContentHash, "h3")
    }

}

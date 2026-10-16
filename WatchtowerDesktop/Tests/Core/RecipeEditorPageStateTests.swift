import XCTest
@testable import WatchtowerCore

@MainActor
final class RecipeEditorPageStateTests: XCTestCase {
    func testNothingIsSentBeforeReady() {
        var state = RecipeEditorPageState()
        let buffer = RecipeBufferModel(automationID: 7, text: "a", contentHash: "h1")
        XCTAssertEqual(state.commands(buffer: buffer, path: "digest.md", readOnly: true), [])
    }

    func testReadOnlyIsSetBeforeShow() {
        var state = RecipeEditorPageState()
        let buffer = RecipeBufferModel(automationID: 7, text: "a", contentHash: "h1")
        state.pageReady()
        XCTAssertEqual(state.commands(buffer: buffer, path: "digest.md", readOnly: true), [
            .setReadOnly(true),
            .show(id: "automation-7", path: "digest.md", text: "a", rev: 1)
        ])
        XCTAssertEqual(state.commands(buffer: buffer, path: "digest.md", readOnly: true), [], "nothing new")
    }

    func testEditableShowSendsNoReadOnly() {
        var state = RecipeEditorPageState()
        let buffer = RecipeBufferModel(automationID: 7, text: "a", contentHash: "h1")
        state.pageReady()
        XCTAssertEqual(state.commands(buffer: buffer, path: "digest.md", readOnly: false), [
            .show(id: "automation-7", path: "digest.md", text: "a", rev: 1)
        ])
    }

    func testResetIsAReloadReplace() {
        var state = RecipeEditorPageState()
        let buffer = RecipeBufferModel(automationID: 7, text: "a", contentHash: "h1")
        state.pageReady()
        _ = state.commands(buffer: buffer, path: "digest.md", readOnly: false)
        buffer.pageSent(text: "ab", base: 1)
        XCTAssertEqual(state.commands(buffer: buffer, path: "digest.md", readOnly: false), [], "the page's own edit")
        buffer.reset(text: "saved", contentHash: "h2")
        XCTAssertEqual(state.commands(buffer: buffer, path: "digest.md", readOnly: false), [
            .reload(id: "automation-7", text: "saved", rev: 2)
        ])
    }

    func testPageRestartShowsAgainOnTheTextsRevision() {
        var state = RecipeEditorPageState()
        let buffer = RecipeBufferModel(automationID: 7, text: "a", contentHash: "h1")
        state.pageReady()
        _ = state.commands(buffer: buffer, path: "digest.md", readOnly: true)
        buffer.reset(text: "disk", contentHash: "h2")
        buffer.pageSent(text: "kept", base: 1)
        state.pageLost()
        XCTAssertEqual(state.commands(buffer: buffer, path: "digest.md", readOnly: true), [])
        state.pageReady()
        XCTAssertEqual(state.commands(buffer: buffer, path: "digest.md", readOnly: true), [
            .setReadOnly(true),
            .show(id: "automation-7", path: "digest.md", text: "kept", rev: 1)
        ])
    }

    /// The same view handed another buffer (a sheet for automation A, then
    /// B; a form that rebuilt its buffer) shows the new one.
    func testRebindShowsTheNewBuffer() {
        var state = RecipeEditorPageState()
        let first = RecipeBufferModel(automationID: 7, text: "a", contentHash: "h1")
        let second = RecipeBufferModel(automationID: 8, text: "b", contentHash: "h9")
        let rebuilt = RecipeBufferModel(automationID: 7, text: "a2", contentHash: "h2")
        XCTAssertFalse(RecipeEditorPageState.needsRebind(from: first, path: "a.md", to: first, path: "a.md"))
        XCTAssertTrue(RecipeEditorPageState.needsRebind(from: first, path: "a.md", to: second, path: "a.md"))
        XCTAssertTrue(RecipeEditorPageState.needsRebind(from: first, path: "a.md", to: rebuilt, path: "a.md"))
        XCTAssertTrue(RecipeEditorPageState.needsRebind(from: first, path: "a.md", to: first, path: "b.md"))

        state.pageReady()
        _ = state.commands(buffer: first, path: "a.md", readOnly: true)
        state.rebound()
        XCTAssertEqual(state.commands(buffer: second, path: "b.md", readOnly: true), [
            .show(id: "automation-8", path: "b.md", text: "b", rev: 1)
        ])
        state.rebound()
        XCTAssertEqual(state.commands(buffer: rebuilt, path: "b.md", readOnly: true), [
            .show(id: "automation-7", path: "b.md", text: "a2", rev: 1)
        ], "the same automation id with a rebuilt buffer is shown afresh, even on the same revision")
    }
}

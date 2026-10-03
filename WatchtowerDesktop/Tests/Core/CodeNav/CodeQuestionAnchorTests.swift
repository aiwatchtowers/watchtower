import XCTest
@testable import WatchtowerCore

/// What a code question is about (spec 2026-10-02 §9.2): the selection, or
/// the cursor line when nothing is selected (⌘I with no selection), and
/// what "Suggest a change" may replace.
final class CodeQuestionAnchorTests: XCTestCase {
    private let file = "import Foundation\nlet value = load(config)\n\nprint(value)\n"

    private func selection(_ text: String, _ range: CodeTextRange, truncated: Bool = false) -> CodeEditorSelection {
        CodeEditorSelection(bufferID: "b1", range: range, text: text, truncated: truncated)
    }

    func testNoSelectionIsTheCursorLine() {
        let anchor = CodeQuestionAnchor.make(path: "Sources/App.swift", selection: nil, cursorLine: 2, fileText: file)
        XCTAssertFalse(anchor.isSelection)
        XCTAssertEqual(anchor.origin, CodeQuestionOrigin(path: "Sources/App.swift", line: 2, selection: nil))
        XCTAssertEqual(anchor.range, CodeTextRange(startLine: 2, startCol: 1, endLine: 2, endCol: 25))
        XCTAssertEqual(anchor.originalText, "let value = load(config)")
        XCTAssertTrue(anchor.canApply)
        let context = CodeQuestionContext.build(folderName: "acme", origin: anchor.origin, language: "swift",
                                                fileText: file) { _ in [] }
        XCTAssertFalse(context.isSelection)
        XCTAssertEqual(context.focusLines, 2...2, "the context is the cursor line")
        XCTAssertEqual(context.focusText, "let value = load(config)")
    }

    /// An empty selection (a caret) is no selection either.
    func testAnEmptySelectionIsTheCursorLine() {
        let caret = selection("", CodeTextRange(startLine: 4, startCol: 3, endLine: 4, endCol: 3))
        let anchor = CodeQuestionAnchor.make(path: "a.swift", selection: caret, cursorLine: 4, fileText: file)
        XCTAssertFalse(anchor.isSelection)
        XCTAssertEqual(anchor.originalText, "print(value)")
        XCTAssertEqual(anchor.origin.line, 4)
    }

    func testCursorLineIsClampedToTheFile() {
        let anchor = CodeQuestionAnchor.make(path: "a.swift", selection: nil, cursorLine: 99, fileText: file)
        XCTAssertEqual(anchor.origin.line, 4)
        XCTAssertEqual(anchor.originalText, "print(value)")
        let empty = CodeQuestionAnchor.make(path: "a.swift", selection: nil, cursorLine: 1, fileText: "")
        XCTAssertEqual(empty.range, CodeTextRange(startLine: 1, startCol: 1, endLine: 1, endCol: 1))
        XCTAssertEqual(empty.originalText, "")
    }

    /// Columns are UTF-16, as Monaco counts them, and a CRLF file's line
    /// stops before its "\r".
    func testCursorLineColumnsAreUTF16WithoutTheLineBreak() {
        let anchor = CodeQuestionAnchor.make(path: "a.swift", selection: nil, cursorLine: 1, fileText: "let s = \"😀\"\r\nx\r\n")
        XCTAssertEqual(anchor.originalText, "let s = \"😀\"")
        XCTAssertEqual(anchor.range.endCol, "let s = \"😀\"".utf16.count + 1)
    }

    func testASelectionIsItsTextAndRange() {
        let range = CodeTextRange(startLine: 2, startCol: 13, endLine: 2, endCol: 25)
        let anchor = CodeQuestionAnchor.make(path: "a.swift", selection: selection("load(config)", range),
                                             cursorLine: 2, fileText: file)
        XCTAssertTrue(anchor.isSelection)
        XCTAssertEqual(anchor.range, range)
        XCTAssertEqual(anchor.originalText, "load(config)")
        XCTAssertEqual(anchor.origin, CodeQuestionOrigin(path: "a.swift", line: 2,
                                                         selection: CodeQuestionSelection(startLine: 2, endLine: 2, text: "load(config)")))
        XCTAssertTrue(anchor.canApply)
    }

    /// A selection over the page's 20 KB limit arrives cut: the question
    /// uses what came, but no change can be applied over it.
    func testATruncatedSelectionCannotBeReplaced() {
        let range = CodeTextRange(startLine: 1, startCol: 1, endLine: 900, endCol: 1)
        let anchor = CodeQuestionAnchor.make(path: "a.swift", selection: selection("cut", range, truncated: true),
                                             cursorLine: 900, fileText: file)
        XCTAssertFalse(anchor.canApply)
        XCTAssertEqual(anchor.applyRefusal(fileProblem: nil), .selectionTooLarge)
    }

    /// Apply is refused while the buffer has a problem with the disk
    /// version (PROJ-03: conflict, deleted, unreadable), and when the page
    /// reports the selected text changed since the question.
    func testApplyRefusals() {
        let anchor = CodeQuestionAnchor.make(path: "a.swift", selection: nil, cursorLine: 2, fileText: file)
        XCTAssertNil(anchor.applyRefusal(fileProblem: nil))
        let conflict = anchor.applyRefusal(fileProblem: "The file changed on disk while you were editing.")
        XCTAssertEqual(conflict, .fileProblem("The file changed on disk while you were editing."))
        XCTAssertTrue(conflict?.message.contains("The file changed on disk") == true)
        XCTAssertEqual(CodeEditApplyRefusal(pageResult: .changed), .selectionChanged)
        XCTAssertEqual(CodeEditApplyRefusal(pageResult: .missing), .editorClosed)
        XCTAssertNil(CodeEditApplyRefusal(pageResult: .applied))
        XCTAssertEqual(CodeEditApplyRefusal.selectionChanged.message,
                       "Not applied: the selected code changed since the question. Ask again for a fresh suggestion.")
    }

    /// After Apply the anchor covers the applied text, so the next
    /// suggestion's guard expects it.
    func testAppliedAnchorCoversTheAppliedText() {
        let range = CodeTextRange(startLine: 2, startCol: 13, endLine: 2, endCol: 25)
        let anchor = CodeQuestionAnchor.make(path: "a.swift", selection: selection("load(config)", range),
                                             cursorLine: 2, fileText: file)
        let one = anchor.applied("load(config, 😀)")
        XCTAssertEqual(one.originalText, "load(config, 😀)")
        XCTAssertEqual(one.range, CodeTextRange(startLine: 2, startCol: 13, endLine: 2, endCol: 13 + "load(config, 😀)".utf16.count))
        let many = anchor.applied("a\r\nbc\n")
        XCTAssertEqual(many.range, CodeTextRange(startLine: 2, startCol: 13, endLine: 4, endCol: 1))
        let two = anchor.applied("a\nbcd")
        XCTAssertEqual(two.range, CodeTextRange(startLine: 2, startCol: 13, endLine: 3, endCol: 4))
        XCTAssertEqual(two.origin.line, 2, "the conversation's context_id line stays")
    }

    func testPageArgumentIsMonacosRange() {
        let range = CodeTextRange(startLine: 2, startCol: 13, endLine: 3, endCol: 1)
        XCTAssertEqual(range.pageArgument as NSDictionary,
                       ["startLine": 2, "startCol": 13, "endLine": 3, "endCol": 1] as NSDictionary)
    }

    /// Pin to inspector and the hand-over to Claude Code (spec §9.5) ship.
    func testPinAndTheHandOverShip() {
        XCTAssertTrue(CodeQuestionActionsFeature.pinToInspector)
        XCTAssertTrue(CodeQuestionActionsFeature.handToClaudeCode)
    }

    /// "Where is it used?" (ruling R45) searches a single identifier: the
    /// selection when it is one, else the identifier at the cursor.
    func testUsageNameIsTheSelectedIdentifierOrTheOneAtTheCursor() {
        let selected = CodeQuestionAnchor.make(
            path: "a.swift", selection: selection(" load ", CodeTextRange(startLine: 2, startCol: 12, endLine: 2, endCol: 18)),
            cursorLine: 2, fileText: file)
        XCTAssertEqual(selected.usageName(cursorCol: nil, fileText: file), "load")
        let phrase = CodeQuestionAnchor.make(
            path: "a.swift", selection: selection("load(config)", CodeTextRange(startLine: 2, startCol: 13, endLine: 2, endCol: 25)),
            cursorLine: 2, fileText: file)
        XCTAssertEqual(phrase.usageName(cursorCol: 20, fileText: file), "config", "the identifier at the cursor")
        XCTAssertEqual(phrase.usageName(cursorCol: 24, fileText: file), "config", "right after the name still names it")
        let line = CodeQuestionAnchor.make(path: "a.swift", selection: nil, cursorLine: 2, fileText: file)
        XCTAssertEqual(line.usageName(cursorCol: 6, fileText: file), "value")
        XCTAssertNil(line.usageName(cursorCol: 11, fileText: file), "the cursor on \" = \" names nothing")
        XCTAssertNil(line.usageName(cursorCol: nil, fileText: file), "no cursor, no name")
    }
}

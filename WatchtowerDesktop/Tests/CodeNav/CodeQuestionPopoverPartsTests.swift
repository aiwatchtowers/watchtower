import CoreGraphics
import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// The Swift halves of the popover's page messages and placement: the
/// `selection` message decoded as the Coordinator does, the ✦ kept inside
/// the editor, and the popover's anchor label.
@MainActor
final class CodeQuestionPopoverPartsTests: XCTestCase {
    func testSelectionMessageDecodes() {
        let body: [String: Any] = ["type": "selection", "id": "b1", "text": "load(config)", "truncated": false,
                                   "startLine": 2, "startCol": 13, "endLine": 2, "endCol": 25]
        XCTAssertEqual(MonacoEditorView.Coordinator.selection(from: body),
                       CodeEditorSelection(bufferID: "b1",
                                           range: CodeTextRange(startLine: 2, startCol: 13, endLine: 2, endCol: 25),
                                           text: "load(config)", truncated: false))
        var cut = body
        cut["truncated"] = true
        XCTAssertEqual(MonacoEditorView.Coordinator.selection(from: cut)?.truncated, true)
        var broken = body
        broken["endCol"] = nil
        XCTAssertNil(MonacoEditorView.Coordinator.selection(from: broken), "a malformed message is dropped")
    }

    /// Right of the selection's box, inside the editor and off its scroll bar.
    func testButtonSitsRightOfTheSelectionInsideTheEditor() {
        let size = CGSize(width: 600, height: 400)
        let center = AskAIButtonOverlay.buttonCenter(for: CGRect(x: 100, y: 50, width: 80, height: 16), in: size)
        XCTAssertEqual(center.x, 100 + 80 + 6 + 12)
        XCTAssertEqual(center.y, 50 + 12 - 4)
        let farRight = AskAIButtonOverlay.buttonCenter(for: CGRect(x: 40, y: 390, width: 580, height: 16), in: size)
        XCTAssertEqual(farRight.x, 600 - 12 - 14, "clamped off the scroll bar")
        XCTAssertEqual(farRight.y, 400 - 12, "clamped into the editor")
    }

    func testAnchorLabelNamesFileAndLines() {
        let one = CodeQuestionAnchor.make(path: "Sources/App.swift", selection: nil, cursorLine: 2, fileText: "a\nb\n")
        XCTAssertEqual(CodeQuestionPopover.anchorLabel(one), "App.swift:2")
        let range = CodeTextRange(startLine: 1, startCol: 1, endLine: 2, endCol: 2)
        let many = CodeQuestionAnchor.make(path: "Sources/App.swift",
                                           selection: CodeEditorSelection(bufferID: "b", range: range, text: "a\nb", truncated: false),
                                           cursorLine: 2, fileText: "a\nb\n")
        XCTAssertEqual(CodeQuestionPopover.anchorLabel(many), "App.swift:1–2")
    }

    /// The popover opens `path:line` links in Files itself; other links
    /// pass the allowlist; the markdown keeps code links only there.
    func testPopoverLinkRoutes() throws {
        let code = try XCTUnwrap(URL(string: CodeLineLinks.url(path: "a.go", line: 1, col: nil)))
        XCTAssertEqual(CodeQuestionPopoverHost.linkRoute(code), .files)
        XCTAssertEqual(CodeQuestionPopoverHost.linkRoute(try XCTUnwrap(URL(string: "https://example.com"))), .systemHandler)
        XCTAssertEqual(CodeQuestionPopoverHost.linkRoute(try XCTUnwrap(URL(string: "smb://host/x"))), .discarded)
        let inline: [MarkdownInline] = [.link(destination: code.absoluteString, children: [.code("a.go:1")])]
        XCTAssertNil(MarkdownView.inlineText(inline).runs.first { $0.link != nil })
        XCTAssertEqual(MarkdownView.inlineText(inline, codeLinks: true).runs.first { $0.link != nil }?.link, code)
    }
}

import XCTest
import AppKit
import WatchtowerChatText
@testable import ChatUI

/// The Workchat field draws its live paste tokens as pills (display only): which ranges get styled, and that the
/// text storage — the draft string, the binding, undo — never carries the style. The view is never put in a window.
@MainActor
final class PasteTokenPillTests: XCTestCase {
    private final class UndoDelegate: NSObject, NSTextViewDelegate {
        let undo: UndoManager = {
            let manager = UndoManager()
            manager.groupsByEvent = false
            return manager
        }()

        func undoManager(for view: NSTextView) -> UndoManager? { undo }
    }

    private var delegate: UndoDelegate!

    override func setUp() {
        super.setUp()
        delegate = UndoDelegate()
    }

    /// A Workchat field: inline pastes on, `livePastes` as given.
    private func makeView(live: [Int: PasteKind], undoable: Bool = false) -> PastingTextView {
        let view = PastingTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.isRichText = false
        view.allowsUndo = true
        if undoable { view.delegate = delegate }
        view.onInlinePaste = { _ in nil }
        view.livePastes = live
        return view
    }

    private func accentAt(_ index: Int, in view: PastingTextView) -> Bool {
        let color = view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil)
        return (color as? NSColor) == PastingTextView.tokenTone
    }

    func testLiveTokensAreStyledAndTheStorageIsNot() throws {
        let view = makeView(live: [1: .image, 2: .text])
        view.string = "fix [Image #1] and [Pasted text #2 +42 lines]"

        XCTAssertEqual(view.tokenRanges, [NSRange(location: 4, length: 10), NSRange(location: 19, length: 26)])
        XCTAssertTrue(accentAt(4, in: view))
        XCTAssertTrue(accentAt(44, in: view))
        XCTAssertFalse(accentAt(0, in: view), "plain text stays plain")
        XCTAssertFalse(accentAt(15, in: view))
        XCTAssertEqual(view.tokenPillRects().count, 2)

        let storage = try XCTUnwrap(view.textStorage)
        XCTAssertNil(storage.attribute(.backgroundColor, at: 4, effectiveRange: nil))
        XCTAssertNotEqual(storage.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor, PastingTextView.tokenTone)
        XCTAssertEqual(view.string, "fix [Image #1] and [Pasted text #2 +42 lines]")
    }

    func testTypedLookalikeAndOtherKindStayPlain() {
        let view = makeView(live: [1: .image])
        view.string = "[Pasted text #1 +3 lines] [Image #2]"

        XCTAssertEqual(view.tokenRanges, [])
        XCTAssertFalse(accentAt(1, in: view))
        XCTAssertEqual(view.tokenPillRects(), [])
    }

    func testDuplicateLabelIsNotStyled() {
        let view = makeView(live: [1: .image])
        view.string = "[Image #1]"
        XCTAssertEqual(view.tokenRanges.count, 1)

        view.string = "[Image #1] [Image #1]"

        XCTAssertEqual(view.tokenRanges, [])
        XCTAssertFalse(accentAt(1, in: view))
        XCTAssertFalse(accentAt(12, in: view))
    }

    func testInlinePastesOffDrawsNoPill() {
        let view = PastingTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.livePastes = [1: .image]
        view.string = "[Image #1]"

        XCTAssertEqual(view.tokenRanges, [])
        XCTAssertFalse(accentAt(1, in: view))
    }

    func testEditsMoveAndBreakThePill() {
        let view = makeView(live: [1: .image])
        view.string = "[Image #1]"

        view.insertText("ab ", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(view.string, "ab [Image #1]")
        XCTAssertEqual(view.tokenRanges, [NSRange(location: 3, length: 10)])
        XCTAssertFalse(accentAt(0, in: view))
        XCTAssertTrue(accentAt(3, in: view))

        view.insertText("x", replacementRange: NSRange(location: 13, length: 0))
        XCTAssertEqual(view.string, "ab [Image #1]x")
        XCTAssertFalse(accentAt(13, in: view), "a character typed after the token is plain")

        view.insertText("", replacementRange: NSRange(location: 4, length: 1))
        XCTAssertEqual(view.string, "ab [mage #1]x")
        XCTAssertEqual(view.tokenRanges, [])
        XCTAssertFalse(accentAt(4, in: view))
    }

    func testLivePastesChangeRestyles() {
        let view = makeView(live: [:])
        view.string = "fix [Image #1]"
        XCTAssertEqual(view.tokenRanges, [])

        view.livePastes = [1: .image]
        XCTAssertEqual(view.tokenRanges, [NSRange(location: 4, length: 10)])
        XCTAssertTrue(accentAt(5, in: view))

        view.livePastes = [:]
        XCTAssertEqual(view.tokenRanges, [])
        XCTAssertFalse(accentAt(5, in: view))
    }

    /// The whole-token Backspace and its undo: the pill goes and comes back with the string.
    func testUndoOfTheWholeTokenDeleteBringsThePillBack() {
        let view = makeView(live: [1: .image], undoable: true)
        view.string = "fix [Image #1]"
        view.setSelectedRange(NSRange(location: 14, length: 0))

        delegate.undo.beginUndoGrouping()
        view.deleteBackward(nil)
        delegate.undo.endUndoGrouping()
        XCTAssertEqual(view.string, "fix ")
        XCTAssertEqual(view.tokenRanges, [])

        delegate.undo.undo()
        XCTAssertEqual(view.string, "fix [Image #1]")
        XCTAssertEqual(view.tokenRanges, [NSRange(location: 4, length: 10)])
        XCTAssertTrue(accentAt(4, in: view))
    }
}

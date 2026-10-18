import XCTest
import AppKit
@testable import WatchtowerDesktop
@testable import WatchtowerCore

/// ⌘V routing in the composer's text view, on private named pasteboards
/// (never the owner's clipboard). The view is never put in a window.
@MainActor
final class PastingTextViewTests: XCTestCase {
    private final class UndoDelegate: NSObject, NSTextViewDelegate {
        let undo: UndoManager = {
            let manager = UndoManager()
            manager.groupsByEvent = false
            return manager
        }()

        func undoManager(for view: NSTextView) -> UndoManager? { undo }
    }

    private var pasteboard: NSPasteboard!
    private var delegate: UndoDelegate!
    private var pasted: [(Data, String)] = []
    private var attachedFiles: [[URL]] = []
    private var longPastes: [LongPaste] = []

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("wt-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        delegate = UndoDelegate()
        pasted = []
        attachedFiles = []
        longPastes = []
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    /// `undoable` gives the view an undo manager (edits must then be
    /// `grouped`); otherwise it has none, as a window-less text view.
    private func makeView(wired: Bool = true, undoable: Bool = false) -> PastingTextView {
        let view = PastingTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.isRichText = false
        view.allowsUndo = true
        if undoable { view.delegate = delegate }
        view.pasteboard = pasteboard
        if wired {
            view.onPasteData = { data, name in
                self.pasted.append((data, name))
                return true
            }
            view.onAttachFiles = { self.attachedFiles.append($0) }
            view.onLongTextPaste = { self.longPastes.append($0) }
        }
        return view
    }

    private func onePixelPNG() throws -> Data {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// One undo group around an edit, as an event would make in the app.
    private func grouped(_ edit: () -> Void) {
        delegate.undo.beginUndoGrouping()
        edit()
        delegate.undo.endUndoGrouping()
    }

    /// `grouped` for an awaited edit (the attach, board #670).
    private func grouped(_ edit: () async -> Void) async {
        delegate.undo.beginUndoGrouping()
        await edit()
        delegate.undo.endUndoGrouping()
    }

    func testImageIsAttachedAndNoTextInserted() async throws {
        let png = try onePixelPNG()
        pasteboard.setData(png, forType: .png)
        let view = makeView()
        view.paste(nil)
        // Handed to the async attach (board #670), which runs right after.
        let attached = await eventually { !self.pasted.isEmpty }
        XCTAssertTrue(attached)
        XCTAssertEqual(pasted.map { $0.1 }, ["Pasted image.png"])
        XCTAssertEqual(pasted.first?.0, png)
        XCTAssertEqual(view.string, "")
    }

    func testPDFIsAttachedAndNoTextInserted() async {
        let pdf = Data("%PDF-1.4\n%fake\n".utf8)
        pasteboard.setData(pdf, forType: .pdf)
        let view = makeView()
        view.paste(nil)
        let attached = await eventually { !self.pasted.isEmpty }
        XCTAssertTrue(attached)
        XCTAssertEqual(pasted.map { $0.1 }, [PastedContent.pdfName])
        XCTAssertEqual(view.string, "")
    }

    func testFinderFilesGoToTheAttachPath() {
        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.md")]
        pasteboard.writeObjects(urls as [NSURL])
        let view = makeView()
        view.paste(nil)
        XCTAssertEqual(attachedFiles, [urls])
        XCTAssertTrue(pasted.isEmpty)
        XCTAssertEqual(view.string, "")
    }

    func testUnwiredViewPastesTextNormally() throws {
        pasteboard.setData(try onePixelPNG(), forType: .png)
        pasteboard.setString("hello", forType: .string)
        let view = makeView(wired: false)
        view.paste(nil)
        XCTAssertEqual(view.string, "hello")
    }

    func testShortTextInsertsWithNoOffer() {
        pasteboard.setString("hello", forType: .string)
        let view = makeView()
        view.string = "say "
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.paste(nil)
        XCTAssertEqual(view.string, "say hello")
        XCTAssertTrue(longPastes.isEmpty)
        XCTAssertTrue(pasted.isEmpty)
    }

    func testLongTextReportsTheInsertedText() throws {
        let long = String(repeating: "x", count: PasteClassifier.longTextThreshold)
        pasteboard.setString(long, forType: .string)
        let view = makeView()
        view.string = "see: "
        view.setSelectedRange(NSRange(location: 5, length: 0))
        view.paste(nil)
        XCTAssertEqual(view.string, "see: " + long)
        let paste = try XCTUnwrap(longPastes.first)
        XCTAssertEqual(paste.text, long)
        XCTAssertTrue(paste.isIntact())
    }

    func testAttachRemovesThePasteOnlyOnSuccessAndUndoRestoresIt() async throws {
        let long = String(repeating: "y", count: PasteClassifier.longTextThreshold)
        pasteboard.setString(long, forType: .string)
        let view = makeView(undoable: true)
        view.string = "a "
        view.setSelectedRange(NSRange(location: 2, length: 0))
        grouped { view.paste(nil) }
        grouped { view.insertText(" b", replacementRange: NSRange(location: (view.string as NSString).length, length: 0)) }
        let paste = try XCTUnwrap(longPastes.first)
        await grouped {
            await paste.attach { data, name in
                XCTAssertEqual(name, PasteClassifier.pastedTextName)
                XCTAssertEqual(data, Data(long.utf8))
                return true
            }
        }
        XCTAssertEqual(view.string, "a  b")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))
        delegate.undo.undo()
        XCTAssertEqual(view.string, "a " + long + " b", "⌘Z puts the attached text back")
    }

    func testRefusedAttachKeepsTheText() async throws {
        let long = String(repeating: "z", count: PasteClassifier.longTextThreshold)
        pasteboard.setString(long, forType: .string)
        let view = makeView()
        view.paste(nil)
        let paste = try XCTUnwrap(longPastes.first)
        await paste.attach { _, _ in false }
        XCTAssertEqual(view.string, long)
    }

    func testEditingThePastedRangeMakesTheOfferStale() async throws {
        let long = String(repeating: "w", count: PasteClassifier.longTextThreshold)
        pasteboard.setString(long, forType: .string)
        let view = makeView()
        view.paste(nil)
        let paste = try XCTUnwrap(longPastes.first)
        view.insertText("!", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertFalse(paste.isIntact(), "text before the paste shifted it: the offer is stale")
        var attachCalls = 0
        await paste.attach { _, _ in
            attachCalls += 1
            return true
        }
        XCTAssertEqual(attachCalls, 0, "a stale paste is never attached")
        XCTAssertEqual(view.string, "!" + long)
    }
}

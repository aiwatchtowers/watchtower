import XCTest
import AppKit
@testable import WatchtowerDesktop
@testable import WatchtowerCore
import WatchtowerChatText
@testable import ChatUI

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
        inlinePastes = []
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

    // MARK: - Inline paste tokens (#2065 §6)

    private var inlinePastes: [InlinePaste] = []

    /// A view with `inlinePastes` on, its `onInlinePaste` answering `label` (nil: the paste is not taken).
    private func makeInlineView(label: String?) -> PastingTextView {
        let view = makeView()
        view.onInlinePaste = { item in
            self.inlinePastes.append(item)
            return label
        }
        return view
    }

    func testInlineImagePasteInsertsTokenAtTheCaret() async throws {
        let png = try onePixelPNG()
        pasteboard.setData(png, forType: .png)
        let view = makeInlineView(label: "[Image #1]")
        view.string = "fix  now"
        view.setSelectedRange(NSRange(location: 4, length: 0))

        view.paste(nil)

        let inserted = await eventually { view.string == "fix [Image #1] now" }
        XCTAssertTrue(inserted, view.string)
        XCTAssertTrue(pasted.isEmpty, "no chip")
        guard case let .image(data, name)? = inlinePastes.first else { return XCTFail("no image paste") }
        XCTAssertEqual(data, png)
        XCTAssertEqual(name, "Pasted image.png")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 14, length: 0), "caret after the token")
    }

    func testInlineLongTextPasteInsertsTokenNoOffer() async throws {
        let long = String(repeating: "x\n", count: PasteClassifier.longTextThreshold / 2)
        pasteboard.setString(long, forType: .string)
        let view = makeInlineView(label: "[Pasted text #1 +5000 lines]")

        view.paste(nil)

        let inserted = await eventually { view.string == "[Pasted text #1 +5000 lines]" }
        XCTAssertTrue(inserted, String(view.string.prefix(40)))
        XCTAssertTrue(longPastes.isEmpty, "no Attach-as-file offer")
        guard case let .text(text)? = inlinePastes.first else { return XCTFail("no text paste") }
        XCTAssertEqual(text, long)
    }

    func testInlineShortTextAndFinderFilesPasteAsBefore() {
        pasteboard.setString("hello", forType: .string)
        let view = makeInlineView(label: "[Pasted text #1 +1 lines]")
        view.paste(nil)
        XCTAssertEqual(view.string, "hello")

        pasteboard.clearContents()
        let urls = [URL(fileURLWithPath: "/tmp/a.png")]
        pasteboard.writeObjects(urls as [NSURL])
        view.paste(nil)
        XCTAssertEqual(attachedFiles, [urls], "a Finder image stays a chip")
        XCTAssertTrue(inlinePastes.isEmpty)
        XCTAssertEqual(view.string, "hello")
    }

    func testRefusedInlinePasteInsertsNothing() async throws {
        pasteboard.setData(try onePixelPNG(), forType: .png)
        let view = makeInlineView(label: nil)
        view.string = "fix"
        view.setSelectedRange(NSRange(location: 3, length: 0))

        view.paste(nil)

        let asked = await eventually { !self.inlinePastes.isEmpty }
        XCTAssertTrue(asked)
        XCTAssertEqual(view.string, "fix")
    }

    /// A token the field cannot insert (the edit refused) is reported back, so its paste does not hold Send.
    func testRefusedTokenInsertIsReported() async throws {
        pasteboard.setData(try onePixelPNG(), forType: .png)
        let view = makeInlineView(label: "[Image #1]")
        var dropped: [String] = []
        view.onInlinePasteDropped = { dropped.append($0) }
        view.string = "fix"
        view.isEditable = false

        view.paste(nil)

        let reported = await eventually { !dropped.isEmpty }
        XCTAssertTrue(reported)
        XCTAssertEqual(dropped, ["[Image #1]"])
        XCTAssertEqual(view.string, "fix")
    }

    func testBackspaceDeletesALiveTokenWhole() {
        let view = makeInlineView(label: nil)
        view.livePastes = [1: .image]
        view.string = "fix [Image #1]"
        view.setSelectedRange(NSRange(location: 14, length: 0))

        view.deleteBackward(nil)

        XCTAssertEqual(view.string, "fix ")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 0))
    }

    func testBackspaceOnAHandTypedTokenDeletesOneCharacter() {
        let view = makeInlineView(label: nil)
        view.string = "fix [Image #1]"
        view.setSelectedRange(NSRange(location: 14, length: 0))

        view.deleteBackward(nil)

        XCTAssertEqual(view.string, "fix [Image #1")
    }

    func testBackspaceWithInlinePastesOffDeletesOneCharacter() {
        let view = makeView()
        view.livePastes = [1: .image]
        view.string = "fix [Image #1]"
        view.setSelectedRange(NSRange(location: 14, length: 0))

        view.deleteBackward(nil)

        XCTAssertEqual(view.string, "fix [Image #1")
    }

    // MARK: - The menu path (#2201 §4): Edit ▸ Paste and ⌘V are enabled by validation before `paste(_:)` runs

    /// The view as the key window's first responder, invisible, so `NSApp.sendAction(_:to: nil, …)` reaches it.
    /// macOS pulls an off-screen `.titled` window back onto the screen, so the window is transparent instead.
    private func inKeyWindow(_ view: PastingTextView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        addTeardownBlock { window.close() }
        window.contentView = view
        XCTAssertTrue(window.makeFirstResponder(view))
        return window
    }

    private func pasteItem() -> NSMenuItem {
        NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    }

    /// What the menu does on ⌘V: validate the item (both entry points AppKit may use), and only when it is
    /// enabled send the action down the responder chain. xctest's app is never active, so its window never
    /// becomes key and `to: nil` would find no responder: the action goes to the window's first responder.
    @discardableResult
    private func menuPaste(_ view: PastingTextView) -> Bool {
        let enabled = view.validateUserInterfaceItem(pasteItem())
        XCTAssertEqual(view.validateMenuItem(pasteItem()), enabled, "the menu's own entry point agrees")
        guard enabled, let responder = view.window?.firstResponder else { return false }
        return NSApp.sendAction(#selector(NSText.paste(_:)), to: responder, from: nil)
    }

    /// The cause (#2201 §4): a plain-text view reads no image type, so AppKit's stock rule disables Paste for a
    /// screenshot-only pasteboard and ⌘V never reaches `paste(_:)`.
    func testPlainTextViewReadsNoImageType() throws {
        pasteboard.setData(try onePixelPNG(), forType: .png)
        let stock = NSTextView(frame: .zero)
        stock.isRichText = false
        XCTAssertNil(pasteboard.availableType(from: stock.readablePasteboardTypes))
        XCTAssertNotNil(pasteboard.availableType(from: makeView().readablePasteboardTypes))
    }

    func testScreenshotPasteIsEnabledAndAttaches() async throws {
        pasteboard.setData(try onePixelPNG(), forType: .png)
        let view = makeInlineView(label: "[Image #1]")
        _ = inKeyWindow(view)

        guard menuPaste(view) else { return XCTFail("a PNG-only pasteboard enables Paste") }

        let asked = await eventually { !self.inlinePastes.isEmpty }
        XCTAssertTrue(asked)
        guard case .image? = inlinePastes.first else { return XCTFail("no image paste") }
    }

    /// A screenshot taken to the clipboard (⌃⇧⌘4) is TIFF only.
    func testTIFFOnlyPasteIsEnabled() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try onePixelPNG()))
        pasteboard.setData(try XCTUnwrap(rep.tiffRepresentation), forType: .tiff)
        let view = makeInlineView(label: "[Image #1]")
        XCTAssertTrue(view.validateUserInterfaceItem(pasteItem()))
    }

    /// Finder writes each copied file as a file reference URL (`file:///.file/id=…`) plus its name as text.
    func testFinderFilePasteAttaches() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wt-paste-\(UUID().uuidString).png")
        try Data([1]).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        // Through NSURL: bridging to `URL` would turn the reference back into a path URL.
        let reference = try XCTUnwrap(
            (file as NSURL).perform(#selector(NSURL.fileReferenceURL))?.takeUnretainedValue() as? NSURL
        )
        let item = NSPasteboardItem()
        item.setString(try XCTUnwrap(reference.absoluteString), forType: .fileURL)
        item.setString(file.lastPathComponent, forType: .string)
        pasteboard.writeObjects([item])
        let view = makeInlineView(label: nil)
        _ = inKeyWindow(view)

        XCTAssertTrue(menuPaste(view))

        let attached = attachedFiles.flatMap { $0 }
        XCTAssertEqual(attached.count, 1)
        XCTAssertFalse(attached.contains { $0.path.hasPrefix("/.file/") }, "the reference is resolved to a path")
        XCTAssertEqual(attached.first?.lastPathComponent, file.lastPathComponent)
        XCTAssertEqual(view.string, "", "the file name is not typed in")
    }

    /// A plain file URL beside the file's name and its icon as TIFF (another shape a Finder copy takes): the file.
    func testFinderFileWithNameAndIconPastesTheFile() throws {
        let file = URL(fileURLWithPath: "/tmp/report.pdf")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try onePixelPNG()))
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        item.setString(file.lastPathComponent, forType: .string)
        item.setData(try XCTUnwrap(rep.tiffRepresentation), forType: .tiff)
        pasteboard.writeObjects([item])
        let view = makeInlineView(label: "[Image #1]")
        _ = inKeyWindow(view)

        XCTAssertTrue(menuPaste(view))

        XCTAssertEqual(attachedFiles, [[file]])
        XCTAssertTrue(inlinePastes.isEmpty, "the icon is not pasted as an image")
        XCTAssertEqual(view.string, "")
    }

    /// GIF or WebP alone: types `PasteClassifier.isImageType` accepts beyond the readable list.
    func testGIFAndWebPOnlyPasteIsEnabled() {
        let view = makeView()
        for type in ["com.compuserve.gif", "org.webmproject.webp"] {
            pasteboard.clearContents()
            pasteboard.setData(Data([0x47, 0x49, 0x46]), forType: NSPasteboard.PasteboardType(type))
            XCTAssertTrue(view.validateUserInterfaceItem(pasteItem()), type)
            XCTAssertTrue(view.validateMenuItem(pasteItem()), type)
        }
        let unwired = makeView(wired: false)
        XCTAssertFalse(unwired.validateUserInterfaceItem(pasteItem()), "a field without attachments takes no GIF")
    }

    /// The paperclip's "Paste …" item: a new `pasteRequest` pastes into the field, once.
    func testPasteRequestPastesOnce() async {
        pasteboard.setString("hello", forType: .string)
        let view = makeView()
        _ = inKeyWindow(view)
        var seen: UUID?
        let request = UUID()

        XCTAssertTrue(ExpandingTextInput.takePasteRequest(request, seen: &seen, into: view))
        XCTAssertFalse(ExpandingTextInput.takePasteRequest(request, seen: &seen, into: view), "the same request again")
        XCTAssertFalse(ExpandingTextInput.takePasteRequest(nil, seen: &seen, into: view))

        let pasted = await eventually { view.string == "hello" }
        XCTAssertTrue(pasted)
        XCTAssertTrue(view.window?.firstResponder === view)
    }

    /// A file URL alone, with no name beside it.
    func testFileURLOnlyPasteIsEnabled() throws {
        let item = NSPasteboardItem()
        item.setString(URL(fileURLWithPath: "/tmp/a.png").absoluteString, forType: .fileURL)
        pasteboard.writeObjects([item])
        let view = makeView()
        XCTAssertTrue(view.validateUserInterfaceItem(pasteItem()))
    }

    /// Without `onPasteData` the field reads only the stock plain-text types (checked on its private pasteboard:
    /// the app's `.general` branch goes to `super`, which a test cannot drive without the owner's clipboard).
    func testUnwiredViewDoesNotEnableImagePaste() throws {
        pasteboard.setData(try onePixelPNG(), forType: .png)
        let view = makeView(wired: false)
        XCTAssertFalse(view.validateUserInterfaceItem(pasteItem()))
    }

    func testReadOnlyFieldDoesNotEnablePaste() throws {
        pasteboard.setData(try onePixelPNG(), forType: .png)
        let view = makeView()
        view.isEditable = false
        XCTAssertFalse(view.validateUserInterfaceItem(pasteItem()))
    }

    func testImageSaveFailureShowsErrorAndInsertsNothing() async throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("wt-paste-\(UUID().uuidString)")
        try Data([0]).write(to: blocker)
        addTeardownBlock { try? FileManager.default.removeItem(at: blocker) }
        let model = WorkchatModel(
            sessionID: 1, control: NoControl(), lineDelivery: SessionLineDelivery(terminalCenter: nil),
            attachmentStore: WorkchatAttachmentStore(root: blocker)
        ) { .claude }
        pasteboard.setData(try onePixelPNG(), forType: .png)
        let view = makeView()
        view.onPasteData = { await model.attach(data: $0, name: $1) }
        view.onInlinePaste = { await model.paste($0) }
        view.string = "fix"
        view.setSelectedRange(NSRange(location: 3, length: 0))
        _ = inKeyWindow(view)

        guard menuPaste(view) else { return XCTFail("a PNG-only pasteboard enables Paste") }

        let failed = await eventually { model.attachmentError != nil }
        XCTAssertTrue(failed)
        let error = try XCTUnwrap(model.attachmentError)
        XCTAssertTrue(error.hasPrefix("Could not save the pasted file: "), error)
        XCTAssertEqual(view.string, "fix")
        XCTAssertTrue(model.pastes.isEmpty)
        XCTAssertTrue(model.attachments.isEmpty)
    }

    /// A Workchat control that reads nothing and sends nothing.
    private final class NoControl: WorkchatControl {
        func lineCheck(_ sessionID: Int64) -> SessionControl.LineCheck { .sessionGone }
        func workchatLineCheck(_ sessionID: Int64) -> SessionControl.LineCheck { .sessionGone }
        func isWorking(_ sessionID: Int64) -> Bool { false }
        func interrupt(_ sessionID: Int64) async throws -> SessionControl.InterruptResult { .notRunning }
        func pendingPermission(_ sessionID: Int64) async throws -> SessionControl.PermissionPrompt? { nil }
        func answerPermission(requestID: Int64, sessionID: Int64, allow: Bool, decidedBy: String) async throws
            -> SessionControl.PermissionAnswer { .notFound }
    }
}

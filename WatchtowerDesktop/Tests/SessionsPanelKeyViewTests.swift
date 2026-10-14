import AppKit
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// The sessions panel's key view (board #480, spec
/// 2026-10-12-sessions-panel-design §4.4): ⌘⌫ and ⌘Z are the panel's only
/// while it is first responder of the key window with no sheet up — a
/// terminal or Monaco with the keyboard keeps them.
@MainActor
final class SessionsPanelKeyViewTests: XCTestCase {
    private var commands: [SessionsPanelKeyView.Command] = []
    private var focus: [Bool] = []

    override func setUp() async throws {
        commands = []
        focus = []
    }

    // MARK: - Harness

    /// The key view beside a terminal-like view that takes the keyboard.
    private func makeWindow() -> (NSWindow, SessionsPanelKeyView.KeyView, NSView) {
        let keys = SessionsPanelKeyView.KeyView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        keys.onCommand = { [weak self] command in
            self?.commands.append(command)
            return command != .handBack
        }
        keys.onFocusChange = { [weak self] in self?.focus.append($0) }
        keys.isKey = { _ in true }
        let terminal = TerminalLike(frame: NSRect(x: 100, y: 0, width: 100, height: 100))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        content.addSubview(keys)
        content.addSubview(terminal)
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        return (window, keys, terminal)
    }

    private func key(
        _ window: NSWindow,
        _ characters: String,
        keyCode: UInt16,
        _ flags: NSEvent.ModifierFlags = [],
        isARepeat: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                       isARepeat: isARepeat, keyCode: keyCode))
    }

    private func click(_ window: NSWindow, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                         clickCount: 1, pressure: 1))
    }

    /// Lets the main queue run what the key view scheduled on it.
    private func drainMainQueue() async {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }

    private func commandDelete(_ window: NSWindow) throws -> NSEvent {
        try key(window, "\u{7f}", keyCode: 51, .command)
    }

    private func commandZ(_ window: NSWindow) throws -> NSEvent {
        try key(window, "z", keyCode: 6, .command)
    }

    // MARK: - Tests

    func testKeysTakenOnlyAsFirstResponder() throws {
        let (window, keys, terminal) = makeWindow()
        defer { window.close() }

        XCTAssertTrue(window.makeFirstResponder(terminal))
        XCTAssertFalse(window.performKeyEquivalent(with: try commandDelete(window)), "the terminal keeps ⌘⌫")
        XCTAssertFalse(window.performKeyEquivalent(with: try commandZ(window)), "the terminal keeps ⌘Z")
        XCTAssertEqual(commands, [])

        XCTAssertTrue(window.makeFirstResponder(keys))
        XCTAssertEqual(focus, [true], "the panel took the keyboard")
        XCTAssertTrue(window.performKeyEquivalent(with: try commandDelete(window)))
        XCTAssertTrue(window.performKeyEquivalent(with: try commandZ(window)))
        XCTAssertFalse(window.performKeyEquivalent(with: try key(window, "z", keyCode: 6, [.command, .shift])), "⌘⇧Z is not Undo")
        keys.keyDown(with: try key(window, "", keyCode: 125))
        keys.keyDown(with: try key(window, "", keyCode: 126))
        keys.keyDown(with: try key(window, "\r", keyCode: CommentEditorKeys.returnKeyCode))
        XCTAssertEqual(commands, [.deleteCursor, .undoDelete, .cursorDown, .cursorUp, .openCursor])

        XCTAssertTrue(window.makeFirstResponder(terminal))
        XCTAssertEqual(focus, [true, false], "a click into the terminal takes the keyboard back")
        XCTAssertFalse(window.performKeyEquivalent(with: try commandDelete(window)))
        XCTAssertEqual(commands.count, 5)
    }

    /// ⌘Z by its key on the owner's Russian layout.
    func testUndoIsReadByItsKeyOnARussianLayout() throws {
        let (window, keys, _) = makeWindow()
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(keys))
        XCTAssertTrue(window.performKeyEquivalent(with: try key(window, "я", keyCode: 6, .command)))
        XCTAssertEqual(commands, [.undoDelete])
    }

    func testNoKeysUnderASheet() throws {
        let (window, keys, _) = makeWindow()
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(keys))

        keys.hasSheet = { _ in true }
        XCTAssertFalse(window.performKeyEquivalent(with: try commandDelete(window)))
        XCTAssertFalse(window.performKeyEquivalent(with: try commandZ(window)))
        keys.isKey = { _ in false }
        keys.hasSheet = { _ in false }
        XCTAssertFalse(window.performKeyEquivalent(with: try commandDelete(window)), "not the key window")
        XCTAssertEqual(commands, [])

        keys.isKey = { _ in true }
        XCTAssertTrue(window.performKeyEquivalent(with: try commandDelete(window)))
        XCTAssertEqual(commands, [.deleteCursor])
    }

    /// Esc hands the keyboard back: to the terminal on screen through the
    /// view model, and with none on screen the panel just lets it go.
    func testEscReturnsFocusToTheTerminal() throws {
        let (window, keys, _) = makeWindow()
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(keys))

        keys.keyDown(with: try key(window, "\u{1b}", keyCode: 53))
        XCTAssertEqual(commands, [.handBack])
        XCTAssertFalse(window.firstResponder === keys, "nothing to hand it to: the panel lets the keyboard go")
        XCTAssertEqual(focus, [true, false])
    }

    /// A requested keyboard (label, header, ✕, Undo) is taken once per
    /// request; a sheet up refuses it.
    func testARequestTakesTheKeyboardUnlessASheetIsUp() throws {
        let (window, keys, terminal) = makeWindow()
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(terminal))

        keys.hasSheet = { _ in true }
        keys.takePanelKeyboard()
        XCTAssertTrue(window.firstResponder === terminal)
        keys.hasSheet = { _ in false }
        keys.takePanelKeyboard()
        XCTAssertTrue(window.firstResponder === keys)
    }

    /// A held ⌘⌫ deletes one row: its auto-repeats are not the panel's.
    func testHeldCommandDeleteIsTakenOnce() throws {
        let (window, keys, _) = makeWindow()
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(keys))

        XCTAssertTrue(window.performKeyEquivalent(with: try commandDelete(window)))
        let repeated = try key(window, "\u{7f}", keyCode: 51, .command, isARepeat: true)
        XCTAssertNil(SessionsPanelKeyView.panelEquivalentCommand(repeated))
        XCTAssertFalse(window.performKeyEquivalent(with: repeated))
        XCTAssertEqual(commands, [.deleteCursor])
    }

    /// Esc the view model served (a running terminal on screen took the
    /// keyboard through its center): the panel does not drop it itself.
    func testEscServedLeavesTheKeyboardToTheTerminalCenter() throws {
        let (window, keys, _) = makeWindow()
        defer { window.close() }
        keys.onCommand = { [weak self] in
            self?.commands.append($0)
            return true
        }
        XCTAssertTrue(window.makeFirstResponder(keys))
        keys.keyDown(with: try key(window, "\u{1b}", keyCode: 53))
        XCTAssertEqual(commands, [.handBack])
        XCTAssertTrue(window.firstResponder === keys, "the terminal takes it once its host attaches")
    }

    /// While the panel has the keyboard a key it has no use for goes
    /// nowhere (no beep up the responder chain); Tab moves the keyboard on.
    func testUnhandledKeysAreSwallowedAndTabMovesOn() throws {
        let (window, keys, terminal) = makeWindow()
        defer { window.close() }
        let recorder = KeyRecorder(frame: .zero)
        keys.nextResponder = recorder
        keys.nextKeyView = terminal
        XCTAssertTrue(window.makeFirstResponder(keys))

        keys.keyDown(with: try key(window, "a", keyCode: 0))
        keys.keyDown(with: try key(window, "\r", keyCode: CommentEditorKeys.returnKeyCode, isARepeat: true))
        XCTAssertEqual(recorder.keys, 0, "swallowed, not passed up to the beep")
        XCTAssertEqual(commands, [])

        keys.keyDown(with: try key(window, "\t", keyCode: 48))
        XCTAssertTrue(window.firstResponder === terminal, "Tab moves the keyboard to the next key view")
        XCTAssertEqual(recorder.keys, 0)
    }

    /// A click takes the keyboard only in this window, inside the list's
    /// frame and off every row — decided by what the click hits.
    func testAClickTakesTheKeyboardOnlyOnTheListsEmptySpace() throws {
        let (window, keys, _) = makeWindow()
        defer { window.close() }
        let row = NSTableRowView(frame: NSRect(x: 0, y: 50, width: 100, height: 20))
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        row.addSubview(cell)
        try XCTUnwrap(window.contentView).addSubview(row)
        let other = NSWindow(contentRect: window.frame, styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }

        XCTAssertTrue(keys.clickTakesPanelKeyboard(try click(window, at: NSPoint(x: 10, y: 10))), "empty list space")
        XCTAssertFalse(keys.clickTakesPanelKeyboard(try click(window, at: NSPoint(x: 10, y: 60))), "a row")
        XCTAssertFalse(keys.clickTakesPanelKeyboard(try click(window, at: NSPoint(x: 150, y: 10))), "the terminal")
        XCTAssertFalse(keys.clickTakesPanelKeyboard(try click(other, at: NSPoint(x: 10, y: 10))), "another window")
        XCTAssertTrue(SessionsPanelKeyView.KeyView.isInsideListRow(cell))
        XCTAssertFalse(SessionsPanelKeyView.KeyView.isInsideListRow(keys))
        XCTAssertFalse(SessionsPanelKeyView.KeyView.isInsideListRow(nil))
    }

    /// The click monitor lives while the view is in a window: removed when
    /// it leaves the window and when SwiftUI dismantles it.
    func testClickMonitorFollowsTheWindowAndDismantle() throws {
        let (window, keys, _) = makeWindow()
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        XCTAssertTrue(keys.isWatchingPanelClicks)

        keys.removeFromSuperview()
        XCTAssertFalse(keys.isWatchingPanelClicks, "left the window")
        content.addSubview(keys)
        XCTAssertTrue(keys.isWatchingPanelClicks)

        SessionsPanelKeyView.dismantleNSView(keys, coordinator: ())
        XCTAssertFalse(keys.isWatchingPanelClicks, "dismantled")
    }

    /// A new `keyboardRequest` serial (what `updateNSView` passes on) is
    /// taken once, after the update; the same serial again takes nothing.
    func testAKeyboardRequestSerialIsTakenOnce() async throws {
        let (window, keys, terminal) = makeWindow()
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(terminal))

        keys.applyKeyboardRequest(0)
        await drainMainQueue()
        XCTAssertTrue(window.firstResponder === terminal, "the serial the view was made with")

        keys.applyKeyboardRequest(1)
        XCTAssertTrue(window.firstResponder === terminal, "not inside the update")
        await drainMainQueue()
        XCTAssertTrue(window.firstResponder === keys)

        XCTAssertTrue(window.makeFirstResponder(terminal))
        keys.applyKeyboardRequest(1)
        await drainMainQueue()
        XCTAssertTrue(window.firstResponder === terminal, "a serial already handled")
    }
}

/// Counts the keys that reach it up the responder chain.
private final class KeyRecorder: NSView {
    var keys = 0
    override func keyDown(with event: NSEvent) {
        keys += 1
    }
}

/// Takes the keyboard like the embedded terminal; no key equivalents.
private final class TerminalLike: NSView {
    override var acceptsFirstResponder: Bool { true }
}

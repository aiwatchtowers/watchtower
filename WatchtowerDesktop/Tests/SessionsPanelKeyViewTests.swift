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
        _ window: NSWindow, _ characters: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                       isARepeat: false, keyCode: keyCode))
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
}

/// Takes the keyboard like the embedded terminal; no key equivalents.
private final class TerminalLike: NSView {
    override var acceptsFirstResponder: Bool { true }
}

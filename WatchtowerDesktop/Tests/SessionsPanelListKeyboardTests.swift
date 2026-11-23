import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop

/// The sessions panel's list never keeps the keyboard a click gave it
/// (#1150): a row click whose tap SwiftUI cancels made the List's table
/// first responder, and the keys typed next went nowhere. The panel's
/// keyboard is its key view's (ask #195); after a mouse-down in the panel
/// the table gives the keyboard back to what had it. A move into the list
/// from the keyboard (Tab, Full Keyboard Access) is left alone.
@MainActor
final class SessionsPanelListKeyboardTests: XCTestCase {
    @MainActor
    final class Rows: ObservableObject {
        @Published var ids = [1, 2, 3]
        @Published var generation = 0
    }

    private struct Panel: View {
        @ObservedObject var rows: Rows
        let onCommand: (SessionsPanelKeyView.Command) -> Bool
        let focusRequest: () -> Int

        var body: some View {
            List {
                ForEach(rows.ids, id: \.self) { Text("Session \($0)").frame(height: 24) }
            }
            .id(rows.generation)
            .background(SessionsPanelKeyView(
                keyboardRequest: 0, onCommand: onCommand, onFocusChange: { _ in }, currentFocusRequest: focusRequest
            ))
            .frame(width: 200, height: 200)
        }
    }

    private struct Harness {
        let window: NSWindow
        let content: NSView
        let hosting: NSView
        let terminal: NSView
        let rows: Rows
    }

    private var commands: [SessionsPanelKeyView.Command] = []
    private var focusRequest = 0

    override func setUp() async throws {
        try WindowServerTestGate.skipIfAbsent()
        commands = []
        focusRequest = 0
    }

    // MARK: - Harness

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    /// Main-queue turns until `condition` holds (at most 50).
    private func drain(until condition: () -> Bool, _ message: String, line: UInt = #line) {
        for _ in 0..<50 where !condition() { drainMainQueue() }
        XCTAssertTrue(condition(), message, line: line)
    }

    /// A few turns, for what must not happen.
    private func settle() {
        for _ in 0..<3 { drainMainQueue() }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        for sub in view.subviews {
            if let found = find(type, in: sub) { return found }
        }
        return nil
    }

    private func harness() throws -> Harness {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        let rows = Rows()
        let hosting = NSHostingView(rootView: Panel(
            rows: rows, onCommand: { [weak self] in self?.commands.append($0); return true },
            focusRequest: { [weak self] in self?.focusRequest ?? 0 }
        ))
        hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        content.addSubview(hosting)
        let terminal = TerminalLike(frame: NSRect(x: 200, y: 0, width: 200, height: 200))
        content.addSubview(terminal)
        window.contentView = content
        drain(until: { find(NSTableView.self, in: hosting) != nil }, "the list is laid out")
        XCTAssertTrue(window.makeFirstResponder(terminal))
        return Harness(window: window, content: content, hosting: hosting, terminal: terminal, rows: rows)
    }

    private func table(_ harness: Harness) throws -> NSTableView {
        try XCTUnwrap(find(NSTableView.self, in: harness.hosting))
    }

    private func keys(_ harness: Harness) throws -> SessionsPanelKeyView.KeyView {
        try XCTUnwrap(find(SessionsPanelKeyView.KeyView.self, in: harness.hosting))
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                         clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
    }

    /// A mouse-down on the first row, dispatched as the app would (the
    /// key view reads it as the current event); its mouse-up is queued.
    private func clickRow(_ harness: Harness) throws {
        let table = try table(harness)
        let row = table.convert(table.rect(ofRow: 0), to: nil)
        let point = NSPoint(x: row.midX, y: row.midY)
        let down = try mouse(.leftMouseDown, at: point, in: harness.window)
        let keys = try keys(harness)
        keys.currentEvent = { down }
        NSApp.postEvent(try mouse(.leftMouseUp, at: point, in: harness.window), atStart: false)
        harness.window.sendEvent(down)
        keys.currentEvent = { nil }
    }

    // MARK: - Tests

    /// The table's own mouse-down makes it first responder
    /// (`refusesFirstResponder` does not stop that): the keyboard goes back.
    func testARowClickLeavesTheKeyboardWhereItWas() throws {
        let harness = try harness()
        try clickRow(harness)
        drain(until: { harness.window.firstResponder === harness.terminal }, "back to the terminal")
    }

    /// Tab, Full Keyboard Access, VoiceOver: no mouse-down, nothing moves.
    func testAMoveIntoTheListFromTheKeyboardIsLeftAlone() throws {
        let harness = try harness()
        let table = try table(harness)
        XCTAssertTrue(harness.window.makeFirstResponder(table))
        settle()
        XCTAssertTrue(harness.window.firstResponder === table)
    }

    /// The row's own open asked for a terminal focus since the click: that
    /// request moves the keyboard, the list gives nothing back.
    func testAFocusAskedSinceTheClickTakesOver() throws {
        let harness = try harness()
        let table = try table(harness)
        let keys = try keys(harness)
        let row = table.convert(table.rect(ofRow: 0), to: nil)
        let down = try mouse(.leftMouseDown, at: NSPoint(x: row.midX, y: row.midY), in: harness.window)
        keys.currentEvent = { down }
        XCTAssertTrue(harness.window.makeFirstResponder(table))
        keys.currentEvent = { nil }
        focusRequest += 1
        settle()
        XCTAssertTrue(harness.window.firstResponder === table, "the request moves it, not the list")
    }

    /// A rebuilt list (new rows, a new table) gives the keyboard back too.
    func testARebuiltListGivesTheKeyboardBack() throws {
        let harness = try harness()
        let first = try table(harness)
        harness.rows.ids = [1, 2, 3, 4, 5]
        harness.rows.generation += 1
        drain(until: { (try? self.table(harness)) !== first }, "a new table")
        try clickRow(harness)
        drain(until: { harness.window.firstResponder === harness.terminal }, "back to the terminal")
    }

    /// What had the keyboard is gone (or hidden) by then: the window takes it.
    func testWithNothingToGiveBackTheWindowTakesIt() throws {
        let harness = try harness()
        try clickRow(harness)
        harness.terminal.isHidden = true
        drain(until: { harness.window.firstResponder === harness.window }, "a hidden holder: the window")
    }

    /// A table elsewhere in the window, clicked outside the panel, keeps it.
    func testATableOutsideThePanelKeepsTheKeyboard() throws {
        let harness = try harness()
        let scroll = NSScrollView(frame: NSRect(x: 300, y: 0, width: 100, height: 100))
        let other = ListLike(frame: scroll.bounds)
        scroll.documentView = other
        harness.content.addSubview(scroll)
        let keys = try keys(harness)
        let outside = try mouse(.leftMouseDown, at: NSPoint(x: 350, y: 50), in: harness.window)
        keys.currentEvent = { outside }
        harness.window.makeFirstResponder(other)
        keys.currentEvent = { nil }
        settle()
        XCTAssertTrue(harness.window.firstResponder === other)
    }

    /// The panel taking the keyboard in the click's turn (its empty space)
    /// keeps it, and its keys work.
    func testThePanelTakingTheKeyboardKeepsIt() throws {
        let harness = try harness()
        let keys = try keys(harness)
        keys.isKey = { _ in true }
        try clickRow(harness)
        keys.takePanelKeyboard()
        settle()
        XCTAssertTrue(harness.window.firstResponder === keys)
        keys.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: harness.window.windowNumber,
            context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125
        )))
        XCTAssertEqual(commands, [.cursorDown])
    }
}

/// Takes the keyboard like the embedded terminal.
private final class TerminalLike: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// Keeps first responder like SwiftUI's list table (a bare NSTableView
/// hands it straight to the window).
private final class ListLike: NSTableView {
    override func becomeFirstResponder() -> Bool { true }
}

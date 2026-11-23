import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop

/// The sessions panel's list never keeps the keyboard (#1150): a row click
/// whose tap SwiftUI cancels made the List's table first responder, and the
/// keys typed next went nowhere. The panel's keyboard is its key view's
/// (ask #195); the table gives the keyboard back to what had it, across
/// list reloads.
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

        var body: some View {
            List {
                ForEach(rows.ids, id: \.self) { Text("Session \($0)").frame(height: 24) }
            }
            .id(rows.generation)
            .background(SessionsPanelKeyView(keyboardRequest: 0, onCommand: onCommand) { _ in })
            .frame(width: 200, height: 200)
        }
    }

    override func setUp() async throws {
        try WindowServerTestGate.skipIfAbsent()
    }

    private func spin() {
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        for sub in view.subviews {
            if let found = find(type, in: sub) { return found }
        }
        return nil
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                         clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
    }

    func testTheListNeverKeepsTheKeyboardAcrossReloads() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let rows = Rows()
        var commands: [SessionsPanelKeyView.Command] = []
        let hosting = NSHostingView(rootView: Panel(rows: rows) { commands.append($0); return true })
        hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        content.addSubview(hosting)
        let terminal = TerminalLike(frame: NSRect(x: 200, y: 0, width: 200, height: 200))
        content.addSubview(terminal)
        window.contentView = content
        spin()
        XCTAssertTrue(window.makeFirstResponder(terminal))

        // A click on a row: the table's own mouse-down makes it first
        // responder (refusesFirstResponder does not stop that); the
        // keyboard goes back to the terminal.
        let table = try XCTUnwrap(find(NSTableView.self, in: hosting))
        let row = table.convert(table.rect(ofRow: 0), to: nil)
        let point = NSPoint(x: row.midX, y: row.midY)
        NSApp.postEvent(try mouse(.leftMouseUp, at: point, in: window), atStart: false)
        window.sendEvent(try mouse(.leftMouseDown, at: point, in: window))
        spin()
        XCTAssertTrue(window.firstResponder === terminal, "a row click leaves the keyboard where it was")

        // Rows change, then the list is rebuilt: its new table gives the
        // keyboard back too; with nothing to give it back to, the window
        // takes it.
        rows.ids = [1, 2, 3, 4, 5]
        spin()
        rows.generation += 1
        spin()
        let rebuilt = try XCTUnwrap(find(NSTableView.self, in: hosting))
        XCTAssertTrue(window.makeFirstResponder(rebuilt))
        spin()
        XCTAssertTrue(window.firstResponder === terminal, "after a reload")
        XCTAssertTrue(window.makeFirstResponder(rebuilt))
        terminal.removeFromSuperview()
        spin()
        XCTAssertTrue(window.firstResponder === window, "what had it is gone")
        content.addSubview(terminal)

        XCTAssertTrue(window.makeFirstResponder(terminal))

        // The panel taking the keyboard in the same turn (an empty-space
        // click) keeps it; its keys still work.
        let keys = try XCTUnwrap(find(SessionsPanelKeyView.KeyView.self, in: hosting))
        keys.isKey = { _ in true }
        XCTAssertTrue(window.makeFirstResponder(rebuilt))
        keys.takePanelKeyboard()
        spin()
        XCTAssertTrue(window.firstResponder === keys)
        keys.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125
        )))
        XCTAssertEqual(commands, [.cursorDown])
    }
}

/// Takes the keyboard like the embedded terminal.
private final class TerminalLike: NSView {
    override var acceptsFirstResponder: Bool { true }
}

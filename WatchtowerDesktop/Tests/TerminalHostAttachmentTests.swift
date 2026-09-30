import AppKit
import XCTest
@testable import WatchtowerDesktop

/// The terminal host is reused when the page switches projects: after
/// A → B → A the container must show A's terminal alone, not B's on top.
@MainActor
final class TerminalHostAttachmentTests: XCTestCase {
    private let margin = TerminalHostAttachment.margin

    func testSwitchingBackShowsTheSelectedProjectsTerminalAlone() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let terminalA = NSView()
        let terminalB = NSView()

        XCTAssertTrue(TerminalHostAttachment.attach(terminalA, to: container))
        XCTAssertTrue(TerminalHostAttachment.attach(terminalB, to: container))
        XCTAssertEqual(container.subviews, [terminalB])

        XCTAssertTrue(TerminalHostAttachment.attach(terminalA, to: container), "switching back re-attaches")
        XCTAssertEqual(container.subviews, [terminalA])
        XCTAssertEqual(terminalA.frame, container.bounds.insetBy(dx: margin, dy: margin), "inset by the margin")
        XCTAssertNil(terminalB.superview)
    }

    func testReattachingTheShownTerminalIsANoOp() {
        let container = NSView()
        let terminal = NSView()
        TerminalHostAttachment.attach(terminal, to: container)
        XCTAssertFalse(TerminalHostAttachment.attach(terminal, to: container))
        XCTAssertEqual(container.subviews, [terminal])
    }

    /// A container left holding a stale second view (the pre-fix state)
    /// is cleaned up even when the wanted terminal is already inside it.
    func testStaleSiblingIsRemovedWhenTheTerminalIsAlreadyInside() {
        let container = NSView()
        let terminal = NSView()
        let stale = NSView()
        container.addSubview(terminal)
        container.addSubview(stale)
        XCTAssertTrue(TerminalHostAttachment.attach(terminal, to: container))
        XCTAssertEqual(container.subviews, [terminal])
    }

    /// The margin holds on every resize, so SwiftTerm's cols/rows always
    /// come from the inset size (the last column is never under the edge).
    func testContainerKeepsTheTerminalInsetAcrossResizes() {
        let container = TerminalContainerView(frame: .zero)
        let terminal = NSView()
        TerminalHostAttachment.attach(terminal, to: container)
        XCTAssertEqual(terminal.frame.size, .zero, "a zero-size container never yields a negative frame")

        container.setFrameSize(NSSize(width: 600, height: 400))
        XCTAssertEqual(terminal.frame, container.bounds.insetBy(dx: margin, dy: margin))
        container.setFrameSize(NSSize(width: 300, height: 200))
        XCTAssertEqual(terminal.frame, container.bounds.insetBy(dx: margin, dy: margin))
    }

    /// The margin is the terminal's own background, following it when the
    /// terminal repaints its layer (OSC 11, reverse video) and cleared when
    /// no terminal is shown.
    func testContainerMirrorsTheTerminalLayerBackground() {
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let terminal = NSView()
        terminal.wantsLayer = true
        terminal.layer?.backgroundColor = NSColor.black.cgColor
        TerminalHostAttachment.attach(terminal, to: container)
        XCTAssertEqual(container.layer?.backgroundColor, NSColor.black.cgColor)

        terminal.layer?.backgroundColor = NSColor.white.cgColor
        XCTAssertEqual(container.layer?.backgroundColor, NSColor.white.cgColor, "a repainted terminal recolours the margin")

        let other = NSView()
        other.wantsLayer = true
        other.layer?.backgroundColor = NSColor.red.cgColor
        TerminalHostAttachment.attach(other, to: container)
        XCTAssertEqual(container.layer?.backgroundColor, NSColor.red.cgColor, "switching follows the shown terminal")
        terminal.layer?.backgroundColor = NSColor.blue.cgColor
        XCTAssertEqual(container.layer?.backgroundColor, NSColor.red.cgColor, "the detached terminal no longer drives it")

        other.removeFromSuperview()
        XCTAssertNil(container.layer?.backgroundColor)
    }
}

import AppKit
import XCTest
@testable import WatchtowerDesktop

/// The terminal host is reused when the page switches projects: after
/// A → B → A the container must show A's terminal alone, not B's on top.
@MainActor
final class TerminalHostAttachmentTests: XCTestCase {
    func testSwitchingBackShowsTheSelectedProjectsTerminalAlone() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let terminalA = NSView()
        let terminalB = NSView()

        XCTAssertTrue(TerminalHostAttachment.attach(terminalA, to: container))
        XCTAssertTrue(TerminalHostAttachment.attach(terminalB, to: container))
        XCTAssertEqual(container.subviews, [terminalB])

        XCTAssertTrue(TerminalHostAttachment.attach(terminalA, to: container), "switching back re-attaches")
        XCTAssertEqual(container.subviews, [terminalA])
        XCTAssertEqual(terminalA.frame, container.bounds)
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
}

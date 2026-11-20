import AppKit
import Metal
import SwiftTerm
import XCTest
@testable import WatchtowerDesktop

/// The embedded terminal draws with SwiftTerm's Metal renderer once it is in
/// a window, and keeps drawing with Core Graphics where Metal is missing
/// (board #2102).
@MainActor
final class TerminalMetalTests: XCTestCase {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        return window
    }

    /// Off-window there is no layer to bind, so a new view starts on Core Graphics.
    func testANewTerminalStartsOnCoreGraphics() {
        let terminal = PalettedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertFalse(terminal.isUsingMetalRenderer)
    }

    /// In a window: Metal where the machine has a device; without one the
    /// view stays on Core Graphics and does not try again.
    func testInAWindowTheTerminalDrawsWithMetalWhereAvailable() {
        let terminal = PalettedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window().contentView?.addSubview(terminal)
        if MTLCreateSystemDefaultDevice() == nil {
            XCTAssertFalse(terminal.isUsingMetalRenderer)
            XCTAssertTrue(PalettedTerminalView.metalUnavailable)
        } else {
            XCTAssertTrue(terminal.isUsingMetalRenderer)
            XCTAssertFalse(PalettedTerminalView.metalUnavailable)
        }
    }

    /// Leaving the window (a session switched away) and joining another keeps
    /// the renderer it had; output fed meanwhile still lands in the grid.
    func testMovingBetweenWindowsKeepsTheRendererAndTheText() throws {
        let terminal = PalettedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window().contentView?.addSubview(terminal)
        let before = terminal.isUsingMetalRenderer
        terminal.removeFromSuperview()
        terminal.feedOutput(Array("moved".utf8)[...])
        window().contentView?.addSubview(terminal)
        XCTAssertEqual(terminal.isUsingMetalRenderer, before)
        XCTAssertEqual(terminal.getTerminal().getLine(row: 0)?.translateToString(trimRight: true), "moved")
    }
}

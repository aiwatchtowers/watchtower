import AppKit
import SwiftTerm
import XCTest
@testable import WatchtowerDesktop

/// Board #1271: a selection survives the session's streaming output while
/// the program has not asked for the mouse; mouse reporting follows the
/// program's mouse mode.
@MainActor
final class TerminalSelectionTests: XCTestCase {
    private func makeTerminal() -> PalettedTerminalView {
        PalettedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    private func bytes(_ text: String) -> ArraySlice<UInt8> { Array(text.utf8)[...] }

    func testMouseReportingOffUntilTheProgramAsks() {
        let terminal = makeTerminal()
        XCTAssertFalse(terminal.allowMouseReporting)

        terminal.feedOutput(bytes("\u{1b}[?1000h"))
        XCTAssertTrue(terminal.allowMouseReporting)

        terminal.feedOutput(bytes("\u{1b}[?1000l"))
        XCTAssertFalse(terminal.allowMouseReporting)
    }

    func testLocalProcessOutputSyncsToo() {
        let terminal = makeTerminal()
        terminal.dataReceived(slice: bytes("\u{1b}[?1002h"))
        XCTAssertTrue(terminal.allowMouseReporting)
    }

    func testSelectionSurvivesOutputAndLineFeeds() {
        let terminal = makeTerminal()
        terminal.feedOutput(bytes("first line\r\nsecond line\r\n"))
        terminal.selectAll()
        XCTAssertTrue(terminal.selectionActive)

        terminal.feedOutput(bytes("\r\u{1b}[2K⠋ Working… (3s)\r\nmore\r\n"))
        XCTAssertTrue(terminal.selectionActive)
    }

    /// The program owns the mouse: SwiftTerm's own clearing stays.
    func testSelectionClearsWhileTheProgramTracksTheMouse() {
        let terminal = makeTerminal()
        terminal.feedOutput(bytes("\u{1b}[?1000htext\r\n"))
        terminal.selectAll()
        terminal.feedOutput(bytes("more\r\n"))
        XCTAssertFalse(terminal.selectionActive)
    }
}

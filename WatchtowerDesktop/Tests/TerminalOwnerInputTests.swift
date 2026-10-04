import AppKit
import SwiftTerm
import XCTest
@testable import WatchtowerDesktop

/// Board #364: an ask's Return hint goes with the owner's next input, so
/// only keystrokes and pastes count — never the app's own paste of the
/// answer line, nor the terminal's replies (a focus report as the terminal
/// takes the keyboard, a device-attributes answer).
@MainActor
final class TerminalOwnerInputTests: XCTestCase {
    func testOnlyTheOwnersInputIsReported() throws {
        let session = SwiftTermSession()
        let terminal = try XCTUnwrap(session.view as? PalettedTerminalView)
        var reported = 0
        session.onOwnerInput = { reported += 1 }

        session.sendInput(Array("\u{1B}[200~Ask #1 answered\u{1B}[201~".utf8))
        terminal.getTerminal().sendResponse(text: "\u{1B}[I")
        terminal.getTerminal().sendResponse(text: "\u{1B}[?1;2c")
        XCTAssertEqual(reported, 0, "the app's paste and the terminal's replies are not the owner's")

        terminal.send(txt: "\r")
        XCTAssertEqual(reported, 1, "a keystroke is")

        session.onOwnerInput = nil
        terminal.send(txt: "x")
        XCTAssertEqual(reported, 1)
    }
}

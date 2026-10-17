import AppKit
import SwiftTerm
import XCTest
@testable import WatchtowerDesktop

/// Board #564: output printed in a workbench terminal cannot read the
/// owner's clipboard through OSC 52; the terminal's other replies still
/// reach the process.
@MainActor
final class TerminalClipboardReadGuardTests: XCTestCase {
    private func makeTerminal() -> (PalettedTerminalView, () -> [UInt8]) {
        let terminal = PalettedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var sent: [UInt8] = []
        terminal.hostInput = { sent.append(contentsOf: $0) }
        return (terminal, { sent })
    }

    func testDelegateAnswersNoClipboardRead() throws {
        let (terminal, _) = makeTerminal()
        let delegate = try XCTUnwrap(terminal.terminalDelegate)
        XCTAssertTrue(delegate is TerminalClipboardReadGuard)
        XCTAssertNil(delegate.clipboardRead(source: terminal))
    }

    /// `ESC ] 52 ; c ; ? BEL` gets no reply (SwiftTerm's default answers
    /// with the pasteboard's text in base64).
    func testOSC52QueryIsNotAnswered() {
        let (terminal, sent) = makeTerminal()
        terminal.feed(byteArray: Array("\u{1B}]52;c;?\u{07}".utf8)[...])
        XCTAssertFalse((String(bytes: sent(), encoding: .utf8) ?? "").contains("52;"), "no OSC 52 reply reaches the pty")
    }

    /// The guard forwards the terminal's other replies: a device-attributes
    /// query (`ESC [ c`) is still answered.
    func testOtherRepliesStillReachTheProcess() {
        let (terminal, sent) = makeTerminal()
        terminal.feed(byteArray: Array("\u{1B}[c".utf8)[...])
        XCTAssertTrue((String(bytes: sent(), encoding: .utf8) ?? "").hasPrefix("\u{1B}[?"), "DA reply forwarded")
    }
}

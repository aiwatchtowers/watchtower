import AppKit
import SwiftTerm
import XCTest
@testable import WatchtowerDesktop

/// Board #564: output printed in a workbench terminal cannot read the
/// owner's clipboard through OSC 52; OSC 52 write and the terminal's other
/// delegate calls still go through. A spy stands in for the view, so no
/// test touches the real pasteboard.
@MainActor
final class TerminalClipboardReadGuardTests: XCTestCase {
    /// Records every `TerminalViewDelegate` call; its clipboard holds text,
    /// so an unguarded OSC 52 query would be answered.
    private final class SpyDelegate: TerminalViewDelegate {
        var calls: [String] = []
        var copied: [Data] = []
        var sent: [UInt8] = []

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { calls.append("sizeChanged") }
        func setTerminalTitle(source: TerminalView, title: String) { calls.append("setTerminalTitle") }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            calls.append("hostCurrentDirectoryUpdate")
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            calls.append("send")
            sent.append(contentsOf: data)
        }
        func scrolled(source: TerminalView, position: Double) { calls.append("scrolled") }
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            calls.append("requestOpenLink")
        }
        func bell(source: TerminalView) { calls.append("bell") }
        func clipboardCopy(source: TerminalView, content: Data) {
            calls.append("clipboardCopy")
            copied.append(content)
        }
        func clipboardRead(source: TerminalView) -> Data? {
            calls.append("clipboardRead")
            return Data("owner-secret".utf8)
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) { calls.append("iTermContent") }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) { calls.append("rangeChanged") }
    }

    private func makeTerminal() -> PalettedTerminalView {
        PalettedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    /// The pin: the app's terminal view routes its delegate calls through the guard.
    func testTerminalViewInstallsTheGuard() throws {
        let terminal = makeTerminal()
        XCTAssertTrue(try XCTUnwrap(terminal.terminalDelegate) is TerminalClipboardReadGuard)
    }

    /// Each of SwiftTerm 1.20's eleven requirements: ten reach the view,
    /// `clipboardRead` never does and answers nil.
    func testForwardsEveryRequirementExceptClipboardRead() {
        let terminal = makeTerminal()
        let spy = SpyDelegate()
        let guardDelegate = TerminalClipboardReadGuard(view: spy)
        guardDelegate.sizeChanged(source: terminal, newCols: 80, newRows: 24)
        guardDelegate.setTerminalTitle(source: terminal, title: "t")
        guardDelegate.hostCurrentDirectoryUpdate(source: terminal, directory: "/tmp")
        guardDelegate.send(source: terminal, data: [0x61][...])
        guardDelegate.scrolled(source: terminal, position: 0.5)
        guardDelegate.requestOpenLink(source: terminal, link: "https://example.com", params: [:])
        guardDelegate.bell(source: terminal)
        guardDelegate.clipboardCopy(source: terminal, content: Data("x".utf8))
        guardDelegate.iTermContent(source: terminal, content: [][...])
        guardDelegate.rangeChanged(source: terminal, startY: 0, endY: 1)
        XCTAssertNil(guardDelegate.clipboardRead(source: terminal))
        XCTAssertEqual(spy.calls, [
            "sizeChanged", "setTerminalTitle", "hostCurrentDirectoryUpdate", "send", "scrolled",
            "requestOpenLink", "bell", "clipboardCopy", "iTermContent", "rangeChanged"
        ])
    }

    /// Through a real terminal: an OSC 52 query (`ESC ] 52 ; c ; ? BEL`) gets
    /// no reply although the clipboard behind the guard holds text, and an
    /// OSC 52 write still reaches `clipboardCopy`.
    func testOSC52QueryIsNotAnsweredAndWriteStillCopies() {
        let terminal = makeTerminal()
        let spy = SpyDelegate()
        let guardDelegate = TerminalClipboardReadGuard(view: spy)
        terminal.terminalDelegate = guardDelegate

        terminal.feed(byteArray: Array("\u{1B}]52;c;?\u{07}".utf8)[...])
        XCTAssertFalse(spy.calls.contains("clipboardRead"))
        XCTAssertTrue(spy.sent.isEmpty, "no OSC 52 reply reaches the pty")

        let payload = Data("copied text".utf8).base64EncodedString()
        terminal.feed(byteArray: Array("\u{1B}]52;c;\(payload)\u{07}".utf8)[...])
        XCTAssertEqual(spy.copied, [Data("copied text".utf8)])
    }

    /// Other terminal replies still reach the process: a device-attributes
    /// query (`ESC [ c`) is answered through the guard.
    func testOtherRepliesStillReachTheProcess() {
        let terminal = makeTerminal()
        var sent: [UInt8] = []
        terminal.hostInput = { sent.append(contentsOf: $0) }
        terminal.feed(byteArray: Array("\u{1B}[c".utf8)[...])
        XCTAssertTrue((String(bytes: sent, encoding: .utf8) ?? "").hasPrefix("\u{1B}[?"), "DA reply forwarded")
    }
}

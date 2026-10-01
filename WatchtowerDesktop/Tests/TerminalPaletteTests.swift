import AppKit
import SwiftTerm
import XCTest
@testable import WatchtowerDesktop

/// The embedded terminal blends into the app window instead of SwiftTerm's
/// default black, stays dark under a light app, and the host's margin
/// follows it.
@MainActor
final class TerminalPaletteTests: XCTestCase {
    private var dark: NSAppearance { get throws { try XCTUnwrap(NSAppearance(named: .darkAqua)) } }
    private var light: NSAppearance { get throws { try XCTUnwrap(NSAppearance(named: .aqua)) } }

    func testWindowBackgroundIsTheDarkWindowBackgroundInSRGB() throws {
        let background = TerminalPalette.windowBackground
        XCTAssertEqual(background.colorSpace, .sRGB, "a concrete colour, not a dynamic one")
        var expected: NSColor?
        try dark.performAsCurrentDrawingAppearance { expected = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) }
        XCTAssertEqual(background, expected)
        XCTAssertEqual(background.alphaComponent, 1)
    }

    /// Dark: transparent, so the window's backdrop shows through and the
    /// terminal matches the header above it. Light: the opaque dark
    /// background, so Claude Code's dark-theme text stays readable.
    func testBackgroundShowsTheWindowThroughOnlyUnderDark() throws {
        XCTAssertEqual(try TerminalPalette.background(for: dark).alphaComponent, 0)
        XCTAssertEqual(try TerminalPalette.background(for: light), TerminalPalette.windowBackground)
    }

    func testAnsiPaletteHasSixteenColours() {
        XCTAssertEqual(TerminalPalette.ansi.count, 16, "installColors ignores any other count")
        let red = TerminalPalette.ansi[1]
        XCTAssertEqual([red.red, red.green, red.blue], [0xFF * 257, 0x45 * 257, 0x3A * 257])
        let blue = TerminalPalette.ansi[4]
        XCTAssertEqual([blue.red, blue.green, blue.blue], [0x40 * 257, 0x9C * 257, 0xFF * 257])
        let dim = TerminalPalette.ansi[8]
        XCTAssertEqual([dim.red, dim.green, dim.blue], [0x8E * 257, 0x8E * 257, 0x93 * 257])
    }

    /// The colours land on the terminal layer at creation and on every
    /// appearance change, and the hosted margin mirrors the layer.
    func testSessionLayerAndHostMarginFollowTheAppearance() throws {
        let session = SwiftTermSession()
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        TerminalHostAttachment.attach(session.view, to: container)
        defer { session.detach() }

        session.view.appearance = try light
        XCTAssertEqual(session.view.layer?.backgroundColor, TerminalPalette.windowBackground.cgColor)
        XCTAssertEqual(container.layer?.backgroundColor, TerminalPalette.windowBackground.cgColor)

        session.view.appearance = try dark
        XCTAssertEqual(session.view.layer?.backgroundColor?.alpha, 0)
        XCTAssertEqual(container.layer?.backgroundColor?.alpha, 0)
    }
}

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

    func testWindowBackgroundIsAConcreteOpaqueSRGBColour() {
        let background = TerminalPalette.windowBackground
        XCTAssertEqual(background.colorSpace, .sRGB, "a concrete colour, not a dynamic one")
        XCTAssertEqual(background.alphaComponent, 1)
    }

    /// Dark: transparent, so the window's backdrop shows through and the
    /// terminal matches the header above it. Light: opaque, so Claude Code's
    /// dark-theme text stays readable.
    func testBackgroundShowsTheWindowThroughOnlyUnderDark() throws {
        XCTAssertEqual(try TerminalPalette.backgroundOpacity(for: dark), 0)
        XCTAssertEqual(try TerminalPalette.backgroundOpacity(for: light), 1)
    }

    func testAnsiPaletteHasSixteenColours() {
        XCTAssertEqual(TerminalPalette.ansi.count, 16, "installColors ignores any other count")
        let red = TerminalPalette.ansi[1]
        XCTAssertEqual([red.red, red.green, red.blue], [0xFF * 257, 0x45 * 257, 0x3A * 257])
        XCTAssertEqual(TerminalPalette.ansi[4], TerminalPalette.ansi[12], "blue is the bright blue in both rows")
        let dim = TerminalPalette.ansi[8]
        XCTAssertEqual([dim.red, dim.green, dim.blue], [0x8E * 257, 0x8E * 257, 0x93 * 257])
    }

    /// The colours are on the view from creation, before any host shows it.
    func testANewTerminalCarriesThePalette() throws {
        let terminal = PalettedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(terminal.nativeForegroundColor, TerminalPalette.foreground)
        XCTAssertEqual(terminal.caretColor, TerminalPalette.caret)
        XCTAssertEqual(terminal.caretTextColor?.alphaComponent, 1, "the glyph under the block cursor stays visible")
        XCTAssertEqual(terminal.selectedTextBackgroundColor, TerminalPalette.selectionBackground)
        XCTAssertEqual(terminal.selectedTextForegroundColor, TerminalPalette.selectionForeground)
        XCTAssertEqual(terminal.backgroundOpacity, TerminalPalette.backgroundOpacity(for: terminal.effectiveAppearance))
        XCTAssertEqual(terminal.layer?.backgroundColor?.alpha, terminal.backgroundOpacity)
    }

    /// Text drawn under light, then a switch to dark: the default-background
    /// cells must turn transparent too, not keep SwiftTerm's cached opaque
    /// colour (the appearance change has to flush its colour cache).
    func testSwitchingToDarkLeavesNoOpaqueCellsBehind() throws {
        let terminal = PalettedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        terminal.appearance = try light
        terminal.getTerminal().feed(text: "hello")
        _ = try render(terminal)

        terminal.appearance = try dark
        let bitmap = try render(terminal)
        // The cell's top-left pixel: inside the run's background fill, above the glyph.
        XCTAssertEqual(bitmap.colorAt(x: 1, y: 1)?.alphaComponent ?? 0, 0, accuracy: 0.01)
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    /// SwiftTerm draws the ⌘-hover link preview's text in the default
    /// background; it must stay opaque when that background is transparent.
    func testLinkPreviewTextStaysOpaque() throws {
        let terminal = PalettedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        terminal.appearance = try dark
        let preview = NSTextField(string: "https://example.com")
        preview.textColor = terminal.nativeBackgroundColor.withAlphaComponent(0)
        terminal.addSubview(preview)
        XCTAssertEqual(preview.textColor, TerminalPalette.windowBackground)
    }

    /// The background follows every appearance change, and the hosted
    /// margin mirrors the terminal layer.
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

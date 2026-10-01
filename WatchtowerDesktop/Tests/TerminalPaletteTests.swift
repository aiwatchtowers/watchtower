import AppKit
import SwiftTerm
import XCTest
@testable import WatchtowerDesktop

/// The embedded terminal blends into the Projects workspace instead of SwiftTerm's
/// default black, stays dark under a light app, and the host's margin
/// follows it.
@MainActor
final class TerminalPaletteTests: XCTestCase {
    private var dark: NSAppearance { get throws { try XCTUnwrap(NSAppearance(named: .darkAqua)) } }
    private var light: NSAppearance { get throws { try XCTUnwrap(NSAppearance(named: .aqua)) } }

    /// The workspace backdrop as dark resolves it — the colour the terminal
    /// shows through to under dark — as a concrete opaque colour.
    func testBackgroundIsTheDarkWorkspaceBackdropAsConcreteOpaqueSRGB() throws {
        let background = TerminalPalette.background
        XCTAssertEqual(background.colorSpace, .sRGB, "a concrete colour, not a dynamic one")
        XCTAssertEqual(background.alphaComponent, 1)
        var expected: NSColor?
        try dark.performAsCurrentDrawingAppearance {
            expected = NSColor.detailBackground.usingColorSpace(.sRGB)
        }
        XCTAssertEqual(background, try XCTUnwrap(expected))
    }

    /// Dark: transparent, so the workspace backdrop shows through and the
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

    /// SwiftTerm draws the ⌘-hover link preview's text in the default
    /// background; it must stay opaque when that background is transparent.
    func testLinkPreviewTextStaysOpaque() throws {
        let terminal = PalettedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        terminal.appearance = try dark
        let preview = NSTextField(string: "https://example.com")
        preview.textColor = terminal.nativeBackgroundColor.withAlphaComponent(0)
        terminal.addSubview(preview)
        XCTAssertEqual(preview.textColor, TerminalPalette.background)
    }

    /// The background follows every appearance change, and the hosted
    /// margin mirrors the terminal layer.
    func testSessionLayerAndHostMarginFollowTheAppearance() throws {
        let session = SwiftTermSession()
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        TerminalHostAttachment.attach(session.view, to: container)
        defer { session.detach() }

        session.view.appearance = try light
        XCTAssertEqual(session.view.layer?.backgroundColor, TerminalPalette.background.cgColor)
        XCTAssertEqual(container.layer?.backgroundColor, TerminalPalette.background.cgColor)

        session.view.appearance = try dark
        XCTAssertEqual(session.view.layer?.backgroundColor?.alpha, 0)
        XCTAssertEqual(container.layer?.backgroundColor?.alpha, 0)
    }
}

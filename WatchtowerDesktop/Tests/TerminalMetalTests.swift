import AppKit
import MetalKit
import SwiftTerm
import XCTest
@testable import WatchtowerDesktop

/// The embedded terminal draws with SwiftTerm's Metal renderer while it is in
/// a window, and keeps drawing with Core Graphics where Metal cannot start
/// (board #2102). The assertions hold on a machine without Metal too (a CI
/// VM): there the fallback is what runs.
@MainActor
final class TerminalMetalTests: XCTestCase {
    private var dark: NSAppearance { get throws { try XCTUnwrap(NSAppearance(named: .darkAqua)) } }
    private var light: NSAppearance { get throws { try XCTUnwrap(NSAppearance(named: .aqua)) } }

    override func setUp() async throws {
        PalettedTerminalView.metalUnavailable = false
    }

    override func tearDown() async throws {
        PalettedTerminalView.metalUnavailable = false
        PalettedTerminalView.startMetal = { try $0.setUseMetal(true) }
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        return window
    }

    /// Runs what is already queued on the main queue (FIFO), no waiting on time.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    private func terminal() -> PalettedTerminalView {
        PalettedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    /// In a window the terminal is on Metal, or — Metal failed to start —
    /// on Core Graphics with the failure remembered; never both, never neither.
    func testInAWindowTheTerminalIsOnMetalOrRemembersWhyNot() {
        let view = terminal()
        XCTAssertFalse(view.isUsingMetalRenderer, "no layer to bind before a window")
        window().contentView?.addSubview(view)
        XCTAssertNotEqual(view.isUsingMetalRenderer, PalettedTerminalView.metalUnavailable)
    }

    /// A failure to start leaves Core Graphics drawing, and no later terminal
    /// tries Metal again this run.
    func testAFailedStartFallsBackAndIsNotRetried() {
        var attempts = 0
        PalettedTerminalView.startMetal = { _ in
            attempts += 1
            throw MetalError.deviceUnavailable
        }
        let first = terminal()
        window().contentView?.addSubview(first)
        XCTAssertFalse(first.isUsingMetalRenderer)
        XCTAssertTrue(PalettedTerminalView.metalUnavailable)

        let second = terminal()
        window().contentView?.addSubview(second)
        XCTAssertFalse(second.isUsingMetalRenderer)
        XCTAssertEqual(attempts, 1)
    }

    /// A session switched away (its view leaves the window) keeps its
    /// renderer — starting one again would cost every switch — and output
    /// fed while away is in the grid when it returns.
    func testLeavingTheWindowKeepsTheRendererAndTheText() throws {
        let view = terminal()
        window().contentView?.addSubview(view)
        try XCTSkipUnless(view.isUsingMetalRenderer, "Metal does not start on this machine")
        view.removeFromSuperview()
        XCTAssertTrue(view.isUsingMetalRenderer)

        view.feedOutput(Array("moved".utf8)[...])
        window().contentView?.addSubview(view)
        XCTAssertTrue(view.isUsingMetalRenderer)
        XCTAssertEqual(view.subviews.filter { $0 is MTKView }.count, 1)
        XCTAssertEqual(view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true), "moved")
    }

    /// The Metal view sits under every other subview (SwiftTerm's progress
    /// bar included), so an opaque Metal layer hides none of them.
    func testTheMetalViewIsUnderEveryOverlay() throws {
        let view = terminal()
        view.appearance = try light
        window().contentView?.addSubview(view)
        try XCTSkipUnless(view.isUsingMetalRenderer, "Metal does not start on this machine")
        XCTAssertTrue(view.subviews.first is MTKView, "\(view.subviews.map { type(of: $0) })")
        XCTAssertEqual(view.subviews.filter { $0 is MTKView }.count, 1)
    }

    /// Any Metal view SwiftTerm adds later (a window rebind, GPU recovery)
    /// goes under the overlays too, whatever position it was added at.
    func testALaterMetalViewIsPutUnderTheOverlays() {
        let view = terminal()
        let overlay = NSView()
        view.addSubview(overlay)
        let metal = MTKView(frame: view.bounds, device: nil)
        view.addSubview(metal, positioned: .above, relativeTo: overlay)
        drainMainQueue()
        XCTAssertTrue(view.subviews.first is MTKView, "\(view.subviews.map { type(of: $0) })")
        XCTAssertGreaterThan(view.subviews.firstIndex(of: overlay) ?? -1, view.subviews.firstIndex(of: metal) ?? Int.max)
    }

    /// Metal clears the terminal's layer; the host's margin still shows the
    /// terminal background — opaque under light, see-through under dark.
    func testTheHostMarginKeepsTheTerminalBackgroundUnderMetal() throws {
        let session = HostedTerminalSession(client: SessionHostClient(
            socketPath: "/tmp/wt-test.sock", cliPath: { nil }, makeTransport: { _ in FakeSessionHostTransport() }
        ))
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window().contentView?.addSubview(container)
        TerminalHostAttachment.attach(session.view, to: container)
        defer { session.detach() }

        session.view.appearance = try light
        XCTAssertEqual(container.layer?.backgroundColor, TerminalPalette.background.cgColor)
        session.view.appearance = try dark
        XCTAssertEqual(container.layer?.backgroundColor?.alpha, 0)
    }

    /// Outside Metal the margin is the layer's colour as before; a clear
    /// layer of a terminal gives the terminal's own background.
    func testMarginColorReadsTheLayerUnlessItIsClear() throws {
        let view = terminal()
        view.appearance = try light
        let red = NSColor.red.cgColor
        XCTAssertEqual(PalettedTerminalView.marginColor(layerColor: red, of: view), red)
        XCTAssertEqual(PalettedTerminalView.marginColor(layerColor: NSColor.clear.cgColor, of: view),
                       TerminalPalette.background.cgColor)
        let plain = NSView()
        XCTAssertEqual(PalettedTerminalView.marginColor(layerColor: NSColor.clear.cgColor, of: plain),
                       NSColor.clear.cgColor)
    }
}

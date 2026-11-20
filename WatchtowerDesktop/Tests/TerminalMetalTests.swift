import AppKit
import MetalKit
import SwiftTerm
import XCTest
@testable import WatchtowerDesktop

/// The embedded terminal draws with SwiftTerm's Metal renderer from its first
/// window on, and keeps drawing with Core Graphics where Metal cannot start
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
        PalettedTerminalView.redrawMetal = { $0.setNeedsDisplay($0.bounds) }
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
        let host = window()
        host.contentView?.addSubview(view)
        try XCTSkipUnless(view.isUsingMetalRenderer, "Metal does not start on this machine")
        let metal = try XCTUnwrap(view.subviews.first { $0 is MTKView })
        view.removeFromSuperview()
        XCTAssertTrue(view.isUsingMetalRenderer)

        view.feedOutput(Array("moved".utf8)[...])
        host.contentView?.addSubview(view)
        XCTAssertTrue(view.isUsingMetalRenderer)
        XCTAssertEqual(view.subviews.filter { $0 is MTKView }.count, 1)
        XCTAssertTrue(view.subviews.first { $0 is MTKView } === metal, "the same renderer, not a rebuilt one")
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

    /// A window a test can make key without activating the app.
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    private func keyWindow() -> NSWindow {
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                               styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        return window
    }

    /// A terminal that comes back into a window where the keyboard is
    /// elsewhere does not keep the focus it had when it left: under Metal
    /// the cursor is drawn from that flag (board #2126).
    func testATerminalBackInItsWindowTakesItsFocusFromTheWindow() throws {
        let host = keyWindow()
        let view = terminal()
        host.contentView?.addSubview(view)
        XCTAssertTrue(host.makeFirstResponder(view))
        XCTAssertTrue(view.hasFocus)

        view.removeFromSuperview()
        host.contentView?.addSubview(view)
        XCTAssertFalse(host.firstResponder === view)
        XCTAssertFalse(view.hasFocus, "focus kept from before it left the window")
    }

    /// A key or visibility change of its own window redraws the Metal view
    /// at once (the cursor is drawn in the frame); another window's change
    /// does not, nor its window's after the view left it.
    func testItsWindowsKeyChangeRedrawsTheMetalFrame() throws {
        let host = keyWindow()
        let view = terminal()
        host.contentView?.addSubview(view)
        try XCTSkipUnless(view.isUsingMetalRenderer, "Metal does not start on this machine")
        let metal = try XCTUnwrap(view.subviews.first { $0 is MTKView })
        var redrawn: [NSView] = []
        PalettedTerminalView.redrawMetal = { redrawn.append($0) }
        let center = NotificationCenter.default

        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            redrawn = []
            center.post(name: name, object: window())
            XCTAssertTrue(redrawn.isEmpty, "\(name.rawValue) of another window")
            center.post(name: name, object: host)
            XCTAssertEqual(redrawn.count, 1, name.rawValue)
            XCTAssertTrue(redrawn.first === metal, name.rawValue)
        }

        view.removeFromSuperview()
        redrawn = []
        center.post(name: NSWindow.didBecomeKeyNotification, object: host)
        XCTAssertTrue(redrawn.isEmpty, "still observing the window it left")
    }

    /// The holder removes its observers when it goes: a terminal freed
    /// while still in a window leaves none behind.
    func testNotificationObserversAreRemovedWithTheirHolder() {
        let name = Notification.Name("TerminalMetalTests.probe")
        var fired = 0
        var holder: NotificationObservers? = NotificationObservers([
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in fired += 1 }
        ])
        NotificationCenter.default.post(name: name, object: nil)
        XCTAssertEqual(fired, 1)
        XCTAssertNotNil(holder)
        holder = nil
        NotificationCenter.default.post(name: name, object: nil)
        XCTAssertEqual(fired, 1)
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

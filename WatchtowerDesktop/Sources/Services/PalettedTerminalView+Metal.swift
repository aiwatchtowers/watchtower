import AppKit
import MetalKit
import os
import SwiftTerm
import WatchtowerCore

/// The embedded terminal draws with SwiftTerm's Metal renderer once it is in
/// a window (board #2102).
extension PalettedTerminalView {
    private static let log = Logger(subsystem: Constants.bundleID, category: "terminal")

    /// Set once Metal failed to start (no device, no shader library or
    /// pipeline): no terminal tries again this run. Settable for tests.
    static var metalUnavailable = false
    /// Starts the renderer; a seam for tests.
    static var startMetal: (TerminalView) throws -> Void = { try $0.setUseMetal(true) }

    /// Metal starts once the view is in a window and stays on for the
    /// view's life: a session switched away keeps its renderer, as starting
    /// one costs 40–60 ms on the main thread (measured; ~5 MB of glyph
    /// atlases per session is the price). A move to another window is
    /// SwiftTerm's own rebind. Where Metal cannot start, or SwiftTerm itself
    /// fell back after repeated GPU failures, the view keeps drawing with
    /// Core Graphics.
    func updateMetalForWindow() {
        guard window != nil else { return }
        if !isUsingMetalRenderer, !Self.metalUnavailable, metalRendererStatus.state != .fellBackToCoreGraphics {
            do {
                try Self.startMetal(self)
            } catch {
                Self.metalUnavailable = true
                Self.log.warning("terminal Metal renderer unavailable, using Core Graphics: \(String(describing: error), privacy: .public)")
            }
        }
        if isUsingMetalRenderer { liftOverlaysAboveMetal() }
        keepLayerBackgroundUnderMetal()
    }

    /// Redraws one Metal view; a seam for tests.
    static var redrawMetal: (MTKView) -> Void = { $0.setNeedsDisplay($0.bounds) }

    /// Under Metal SwiftTerm 1.20 draws the cursor inside the frame, from
    /// `hasFocus` as it is when the frame draws — no longer a layer of its
    /// own that follows focus by itself (board #2126). Two gaps left a
    /// stale cursor (hollow, or solid where the keyboard is elsewhere):
    /// AppKit does not resign a first responder that leaves its window, so
    /// a session switched back kept its old focus; and a key or visibility
    /// change of the window redraws only through SwiftTerm's coalesced,
    /// deferred request. So on every move into a window and on every key
    /// or occlusion change of that window the focus is taken from the
    /// window's first responder (SwiftTerm still ANDs in key status) and
    /// the Metal frame is redrawn at once.
    func syncFocusWithWindow() {
        guard let window else { return }
        hasFocus = window.firstResponder === self
        guard isUsingMetalRenderer else { return }
        for case let metal as MTKView in subviews {
            Self.redrawMetal(metal)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMetalForWindow()
        observeWindowFocus()
        syncFocusWithWindow()
    }

    /// Observes this view's own window for `syncFocusWithWindow`, dropping
    /// the previous window's observers; none outside a window.
    private func observeWindowFocus() {
        windowFocusObservers.forEach(NotificationCenter.default.removeObserver)
        windowFocusObservers = []
        guard let window else { return }
        let names = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification]
        windowFocusObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncFocusWithWindow() }
            }
        }
    }

    /// SwiftTerm's Metal renderer clears the view's layer and paints the
    /// background in its own; the host's margin mirrors that layer, and a
    /// clear set over a clear layer notifies nobody (an appearance change
    /// would not reach the margin). So under Metal the layer keeps the
    /// terminal's background — harmless under the Metal layer, as the
    /// palette's background is either opaque or fully clear. Called after
    /// every palette background change.
    func keepLayerBackgroundUnderMetal() {
        guard isUsingMetalRenderer else { return }
        layer?.backgroundColor = nativeBackgroundColor.cgColor
    }

    /// The colour a host's margin around `view` shows: the view's layer
    /// background, or — where that is fully clear, as SwiftTerm's Metal
    /// renderer leaves it (it draws the background itself) — the terminal's
    /// own background, alpha included. Under Metal the margin does not
    /// follow reverse video.
    static func marginColor(layerColor: CGColor?, of view: NSView) -> CGColor? {
        guard let terminal = view as? TerminalView, (layerColor?.alpha ?? 0) == 0 else { return layerColor }
        return terminal.nativeBackgroundColor.cgColor
    }

    /// SwiftTerm inserts its Metal view (at start, on a window rebind, on GPU
    /// recovery) above the OSC 9;4 progress bar, which an opaque (light
    /// appearance) Metal layer then hides. AppKit settles a subview's
    /// position only after `didAddSubview`, so a Metal view added later
    /// (GPU recovery) has the overlays lifted on the next main-queue turn.
    func liftOverlaysIfMetalView(_ added: NSView) {
        guard added is MTKView else { return }
        DispatchQueue.main.async { [weak self] in self?.liftOverlaysAboveMetal() }
    }

    /// Every subview but the Metal view goes back on top, in its order.
    private func liftOverlaysAboveMetal() {
        for overlay in subviews where !(overlay is MTKView) {
            addSubview(overlay, positioned: .above, relativeTo: nil)
        }
    }
}

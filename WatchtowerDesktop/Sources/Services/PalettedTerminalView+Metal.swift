import AppKit
import MetalKit
import os
import SwiftTerm
import WatchtowerCore

/// The embedded terminal draws with SwiftTerm's Metal renderer while it is
/// in a window (board #2102).
extension PalettedTerminalView {
    private static let log = Logger(subsystem: Constants.bundleID, category: "terminal")

    /// Set once Metal failed to start (no device, no shader library or
    /// pipeline): no terminal tries again this run. Settable for tests.
    static var metalUnavailable = false
    /// Starts the renderer; a seam for tests.
    static var startMetal: (TerminalView) throws -> Void = { try $0.setUseMetal(true) }

    /// Metal is on only while the view is in a window: a session switched
    /// away (its view leaves the window) releases its GPU renderer and glyph
    /// atlases, so open sessions cost GPU memory only on screen. A move to
    /// another window is SwiftTerm's own rebind. Where Metal cannot start, or
    /// SwiftTerm itself fell back after repeated GPU failures, the view keeps
    /// drawing with Core Graphics.
    func updateMetalForWindow() {
        guard window != nil else {
            if isUsingMetalRenderer { try? setUseMetal(false) }
            return
        }
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

    /// SwiftTerm inserts its Metal view above the OSC 9;4 progress bar, which
    /// an opaque (light appearance) Metal layer then hides: every subview but
    /// the Metal view goes back on top, in its order.
    private func liftOverlaysAboveMetal() {
        for overlay in subviews where !(overlay is MTKView) {
            addSubview(overlay, positioned: .above, relativeTo: nil)
        }
    }
}

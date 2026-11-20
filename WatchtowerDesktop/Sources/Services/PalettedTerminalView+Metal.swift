import AppKit
import os
import SwiftTerm
import WatchtowerCore

/// The embedded terminal draws with SwiftTerm's Metal renderer (board #2102).
extension PalettedTerminalView {
    private static let log = Logger(subsystem: Constants.bundleID, category: "terminal")

    /// Set once Metal failed to start: the machine has no Metal device or the
    /// pipeline cannot be built, so no terminal tries again this run.
    private(set) static var metalUnavailable = false

    /// Switches the Metal renderer on once the view is in a window (SwiftTerm
    /// needs one to bind its layer); a later move to another window is
    /// SwiftTerm's own rebind. On failure the view keeps drawing with Core
    /// Graphics.
    func enableMetalIfPossible() {
        guard window != nil, !Self.metalUnavailable, !isUsingMetalRenderer else { return }
        do {
            try setUseMetal(true)
        } catch {
            Self.metalUnavailable = true
            Self.log.warning("terminal Metal renderer unavailable, using Core Graphics: \(String(describing: error), privacy: .public)")
        }
    }
}

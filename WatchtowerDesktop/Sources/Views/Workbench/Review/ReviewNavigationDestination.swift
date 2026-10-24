import AppKit
import SwiftUI
import WatchtowerCore

/// Branch review as a place code jumps land (board #960, spec §2): the
/// pane's `ReviewChangesModel` behind `CodeLocationDestination`. It is the
/// key destination while its window is the one the owner works in and the
/// keyboard focus is inside the pane — with Files beside it, whichever pane
/// holds the focus gets the jump. It is also the pane's page for the
/// Navigate menu's Go to Definition and Show All Usages (the centres ask
/// the key destination before the Files pane's page), and the place its
/// pages' `definition` and `usages` messages go through.
@MainActor
final class ReviewNavigationDestination: CodeLocationDestination, CodeDefinitionPage, CodeUsagesPage {
    weak var model: ReviewChangesModel?
    var root: CodeRoot?
    /// A view spanning the pane (`ReviewDestinationAnchor`).
    weak var anchor: NSView?
    /// The centres the pages' messages go to; nil = no navigation.
    weak var definitions: CodeNavigationCenter?
    weak var usages: CodeUsagesCenter?
    /// The page on screen, the diff's or the preview's.
    weak var page: (any CodeDefinitionPage & CodeUsagesPage)?

    var isKeyDestination: Bool {
        guard let anchor, let window = anchor.window else { return false }
        // Open Quickly's panel takes key while it is up; the window under it
        // stays main and keeps its first responder.
        guard window.isKeyWindow || window.isMainWindow,
              let responder = window.firstResponder as? NSView, responder.window === window else { return false }
        let pane = anchor.convert(anchor.bounds, to: nil).insetBy(dx: -1, dy: -1)
        return pane.contains(responder.convert(responder.bounds, to: nil))
    }

    /// Declined (Files opens it) while the pane shows no file area: the
    /// round is not ready, or Deep's Meaning or Wrap-up is on screen.
    func show(_ location: CodeNavLocation, root: CodeRoot) -> Bool {
        guard root == self.root, let model = modelShowingFiles else { return false }
        return model.showLocation(location)
    }

    var currentLocation: CodeNavLocation? { model?.currentLocation }

    /// Under the file area; declined when there is none, as `show` is.
    func showUsagesList() -> Bool {
        guard let model = modelShowingFiles else { return false }
        model.showUsages()
        return true
    }

    private var modelShowingFiles: ReviewChangesModel? {
        guard let model, model.load == .ready, model.hasChanges,
              model.mode == .quick || model.phase == .chapters else { return nil }
        return model
    }

    func requestDefinitionAtCursor() async -> Bool {
        await page?.requestDefinitionAtCursor() ?? false
    }

    func requestUsagesAtCursor() async -> Bool {
        await page?.requestUsagesAtCursor() ?? false
    }
}

/// An empty view behind the whole pane: where the pane is in its window.
struct ReviewDestinationAnchor: NSViewRepresentable {
    let destination: ReviewNavigationDestination

    func makeNSView(context: Context) -> PassThroughView {
        let view = PassThroughView()
        destination.anchor = view
        return view
    }

    func updateNSView(_ view: PassThroughView, context: Context) {
        destination.anchor = view
    }

    /// Never takes a click.
    final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

import AppKit
import SwiftUI

/// Keeps the enclosing scroll view's vertical scroller at the trailing edge
/// of the visible area (#1073). A scroll view under an `.inspector` column
/// spans the column too: SwiftUI moves its scroller left with
/// `scrollerInsets.right` while the column is open, frame by frame of the
/// column's animation, and never writes the final value. A close whose last
/// frames are skipped (a busy main thread) leaves the scroller where the
/// column's edge was, and it flashes in the middle of the feed on the next
/// scroll. This view writes the settled value — `trailing`, the feed's
/// trailing safe area — once the update is applied and again on the next
/// turn of the run loop, after SwiftUI's own writes. Placed in the scroll
/// view's content; no layout, no drawing, no hits.
struct FeedScrollerInset: NSViewRepresentable {
    let trailing: CGFloat

    final class InsetView: NSView {
        var trailing: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            settle()
            DispatchQueue.main.async { [weak self] in self?.settle() }
        }

        /// The scroller's trailing inset is `trailing`; nothing is written
        /// when it already is.
        func settle() {
            guard let scrollView = enclosingScrollView, scrollView.scrollerInsets.right != trailing else { return }
            var insets = scrollView.scrollerInsets
            insets.right = trailing
            scrollView.scrollerInsets = insets
        }
    }

    func makeNSView(context: Context) -> InsetView {
        let view = InsetView()
        view.trailing = trailing
        return view
    }

    func updateNSView(_ view: InsetView, context: Context) {
        view.trailing = trailing
        view.apply()
    }
}

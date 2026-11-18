import AppKit
import SwiftUI

/// Keeps the enclosing scroll view's vertical scroller at the trailing edge
/// of the visible area (#1073). A scroll view under an `.inspector` column
/// spans the column too: SwiftUI moves its scroller left with
/// `scrollerInsets.right` while the column is open, frame by frame of the
/// column's animation, and never writes the final value. A close whose last
/// frames are skipped (a busy main thread) leaves the scroller where the
/// column's edge was, and it flashes in the middle of the feed on the next
/// scroll.
///
/// This view overrides that SwiftUI-owned value: it writes `trailing`, the
/// feed's trailing safe area, when it is updated, again on the next turn of
/// the run loop, and on every scroll of the feed (the clip view's bounds
/// change — exactly when a stale knob would show). At a settled state SwiftUI
/// and this view write the same value, so they never fight; only a stale
/// mid-animation value differs, and that is the one replaced. Placed in the
/// scroll view's content; no layout, no drawing, no hits.
struct FeedScrollerInset: NSViewRepresentable {
    let trailing: CGFloat

    final class InsetView: NSView {
        var trailing: CGFloat = 0
        private var scrollObserver: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeScrolling()
            apply()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            observeScrolling()
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

        /// Follows the clip view of the scroll view this view is in while it
        /// is in a window; nothing otherwise.
        private func observeScrolling() {
            stopObserving()
            guard window != nil, let clip = enclosingScrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.settle() }
            }
        }

        func stopObserving() {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            scrollObserver = nil
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

    static func dismantleNSView(_ view: InsetView, coordinator: ()) {
        view.stopObserving()
    }
}

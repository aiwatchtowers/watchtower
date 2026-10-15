import AppKit
import SwiftUI

/// The sessions panel's swipe back to the workbench list (board #743), laid
/// behind the panel. A local monitor takes a swipe over the panel's frame in
/// this window, with no sheet and no Go to… palette up (⌘['s gates): a
/// three-finger swipe right (`.swipe`), or — with "Swipe between pages" on
/// two fingers — a clearly sideways two-finger scroll, tracked the way
/// Safari tracks Back (`trackSwipeEvent`). The panel scrolls only up and
/// down, so a sideways scroll over it has no other owner.
struct WorkbenchBackSwipeCatcher: NSViewRepresentable {
    /// Off under the Go to… palette, an overlay rather than a sheet.
    let isEnabled: Bool
    let onBack: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.isEnabled = isEnabled
        view.onBack = onBack
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.stopWatchingSwipes()
    }

    /// A three-finger swipe (`.swipe`) to the right: AppKit reports it as a
    /// positive `deltaX`, as Safari's Back reads it.
    static func isBackSwipe(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        deltaX > 0 && abs(deltaX) > abs(deltaY)
    }

    /// A two-finger scroll that may start a tracked back swipe: its first
    /// event (`.began`), at least twice as sideways as up or down — a
    /// scroll of the list that merely leans stays the list's — with swipe
    /// tracking from scroll events on in System Settings.
    static func startsTrackedSwipe(
        phase: NSEvent.Phase, deltaX: CGFloat, deltaY: CGFloat, trackingEnabled: Bool
    ) -> Bool {
        trackingEnabled && phase == .began && deltaX != 0 && abs(deltaX) >= 2 * abs(deltaY)
    }

    /// The tracked swipe went back: it ended (not cancelled short of the
    /// threshold) on the back side.
    static func trackedSwipeGoesBack(amount: CGFloat, phase: NSEvent.Phase) -> Bool {
        phase == .ended && amount > 0
    }

    final class CatcherView: NSView {
        var isEnabled = true
        var onBack: (() -> Void)?
        /// Whether a sheet is up; a seam for tests.
        var hasSheet: @MainActor (NSWindow) -> Bool = { $0.attachedSheet != nil }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watchSwipes()
        }

        /// Whether the local monitor is installed; a seam for tests.
        var isWatchingSwipes: Bool { monitor != nil }

        /// A local monitor while it is in a window; gone once it leaves.
        private func watchSwipes() {
            guard window != nil else {
                stopWatchingSwipes()
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.swipe, .scrollWheel]) { [weak self] event in
                let taken = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return taken ? nil : event
            }
        }

        func stopWatchingSwipes() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// The event is a swipe over this view's frame that this view took.
        private func handle(_ event: NSEvent) -> Bool {
            guard isOverPanel(event) else { return false }
            switch event.type {
            case .swipe:
                guard WorkbenchBackSwipeCatcher.isBackSwipe(deltaX: event.deltaX, deltaY: event.deltaY) else {
                    return false
                }
                onBack?()
                return true
            case .scrollWheel:
                guard WorkbenchBackSwipeCatcher.startsTrackedSwipe(
                    phase: event.phase, deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                    trackingEnabled: NSEvent.isSwipeTrackingFromScrollEventsEnabled
                ) else { return false }
                trackBackSwipe(event)
                return true
            default:
                return false
            }
        }

        /// Only the back direction is allowed (`0...1`): a swipe the other
        /// way tracks nothing.
        private func trackBackSwipe(_ event: NSEvent) {
            var wentBack = false
            event.trackSwipeEvent(
                options: [.lockDirection, .clampGestureAmount],
                dampenAmountThresholdMin: 0, max: 1
            ) { [weak self] amount, phase, _, _ in
                guard !wentBack, WorkbenchBackSwipeCatcher.trackedSwipeGoesBack(amount: amount, phase: phase) else {
                    return
                }
                wentBack = true
                MainActor.assumeIsolated { self?.onBack?() }
            }
        }

        /// An event in this window, inside this view's frame, the catcher
        /// on and no sheet up.
        func isOverPanel(_ event: NSEvent) -> Bool {
            guard isEnabled, let window, event.window === window, !hasSheet(window) else { return false }
            return convert(bounds, to: nil).contains(event.locationInWindow)
        }
    }
}

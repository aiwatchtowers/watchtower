import AppKit
import SwiftUI
import WatchtowerCore

/// Double Shift (spec §8.1): a local `NSEvent` monitor that feeds
/// `DoubleShiftDetector` with the key events of one window — the workbench
/// window while it is key — and calls `onDoubleShift`. Never global.
@MainActor
final class DoubleShiftMonitor {
    private var monitor: Any?
    private var detector = DoubleShiftDetector()
    private weak var window: NSWindow?
    private let onDoubleShift: () -> Void

    init(onDoubleShift: @escaping () -> Void) {
        self.onDoubleShift = onDoubleShift
    }

    /// Listens to `window`'s events (nil stops).
    func watch(_ window: NSWindow?) {
        self.window = window
        detector = DoubleShiftDetector()
        if window == nil {
            stopWatching()
        } else if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.observe(event) }
                return event
            }
        }
    }

    func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func observe(_ event: NSEvent) {
        guard let window, event.window === window, window.isKeyWindow else {
            detector.otherKeyPressed()
            return
        }
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command, .function])
        let isShiftKey = event.keyCode == 56 || event.keyCode == 60 // left, right Shift
        guard event.type == .flagsChanged, isShiftKey else {
            detector.otherKeyPressed()
            return
        }
        if flags == .shift {
            // A Shift went down with no other modifier held.
            if detector.shiftPressed(at: event.timestamp) { onDoubleShift() }
        } else if !flags.isEmpty {
            detector.otherKeyPressed()
        } // empty: a Shift went up
    }
}

/// Behind the workbench page: tells `OpenQuicklyCenter` the workbench is on
/// screen (and in which window) while the page is in a window, and runs the
/// double-Shift monitor for that window. The page leaving — another tab,
/// another workbench, a standalone terminal — closes the panel.
struct OpenQuicklyHostView: NSViewRepresentable {
    let center: OpenQuicklyCenter
    let project: Workbench

    func makeNSView(context: Context) -> OpenQuicklyHostNSView {
        let view = OpenQuicklyHostNSView()
        view.center = center
        view.project = project
        return view
    }

    func updateNSView(_ view: OpenQuicklyHostNSView, context: Context) {
        guard view.project?.id != project.id || view.project?.folderURL != project.folderURL else { return }
        if let old = view.project { center.pageDisappeared(workbenchID: old.id) }
        view.project = project
        view.announce()
    }

    static func dismantleNSView(_ view: OpenQuicklyHostNSView, coordinator: ()) {
        view.leave()
    }
}

final class OpenQuicklyHostNSView: NSView {
    weak var center: OpenQuicklyCenter?
    var project: Workbench?
    private lazy var doubleShift = DoubleShiftMonitor { [weak self] in
        self?.center?.present(scope: .all)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            leave()
        } else {
            announce()
        }
    }

    func announce() {
        guard let window, let project else { return }
        center?.pageAppeared(project, window: window)
        doubleShift.watch(window)
    }

    func leave() {
        doubleShift.stopWatching()
        if let project { center?.pageDisappeared(workbenchID: project.id) }
    }
}

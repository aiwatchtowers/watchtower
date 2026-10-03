import AppKit
import Quartz
import SwiftUI
import WatchtowerCore

/// Open Quickly's window (spec §8.1): a borderless, non-activating floating
/// panel 680 pt wide, centred over the top third of the workbench window and
/// attached to it. Esc or a click outside closes it (through
/// `OpenQuicklyCenter`, which also closes it when the workbench leaves the
/// screen). Keys are taken before the search field sees them: ↑↓ move,
/// ↩ ⌥↩ ⌘↩ act, Esc closes, Space toggles Quick Look while moving through
/// the rows.
@MainActor
final class OpenQuicklyPanelController: NSObject, OpenQuicklyPresenting, NSWindowDelegate {
    static let width: CGFloat = 680

    private var panel: OpenQuicklyNSPanel?
    private weak var parent: NSWindow?
    private weak var center: OpenQuicklyCenter?
    private weak var session: OpenQuicklySession?
    private let previous = PreviousFirstResponder()
    private let quickLook = OpenQuicklyQuickLookSource()

    func presentPanel(_ session: OpenQuicklySession, center: OpenQuicklyCenter, over window: NSWindow?) {
        self.center = center
        if let panel, self.session === session {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        dismissPanel(restoringFocus: false)
        previous.capture()
        self.session = session
        let panel = OpenQuicklyNSPanel(quickLook: quickLook)
        panel.delegate = self
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        let host = NSHostingView(rootView: OpenQuicklyView(session: session) { [weak self] option in
            self?.activate(option: option, command: false)
        })
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        place(panel, over: window)
        parent = window
        window?.addChildWindow(panel, ordered: .above)
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func dismissPanel(restoringFocus: Bool) {
        guard let panel else { return }
        self.panel = nil
        session = nil
        if Self.quickLookVisible { QLPreviewPanel.shared()?.orderOut(nil) }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKey()
        if restoringFocus { previous.restore() }
    }

    /// Centred horizontally; its middle on the line a third down the window,
    /// kept inside the screen.
    private func place(_ panel: NSPanel, over window: NSWindow?) {
        let size = panel.frame.size
        guard let window else {
            panel.center()
            return
        }
        let frame = window.frame
        var origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height / 3 - size.height / 2)
        if let visible = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let session, let center else { return false }
        // An input method composing in the field keeps its keys.
        if let editor = panel?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 126, 125: // ↑ ↓
            guard flags.subtracting([.numericPad, .function]).isEmpty else { return false }
            session.move(event.keyCode == 126 ? .up : .down)
            updateQuickLook()
            return true
        case 36, 76: // Return, Enter
            activate(option: flags.contains(.option), command: flags.contains(.command))
            return true
        case 53: // Esc
            center.dismiss(restoringFocus: true)
            return true
        case 49 where flags.isEmpty: // Space
            guard case let .toggleQuickLook(path) = session.spaceAction(quickLookShown: Self.quickLookVisible) else { return false }
            toggleQuickLook(session.project.folderURL.appendingPathComponent(path))
            return true
        default:
            return false
        }
    }

    private func activate(option: Bool, command: Bool) {
        guard let session, let center else { return }
        center.perform(session.activateSelection(option: option, command: command))
    }

    // MARK: Quick Look

    private static var quickLookVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }

    /// Shown without taking the keyboard: the search panel stays key and
    /// Space hides it again.
    private func toggleQuickLook(_ url: URL) {
        guard let preview = QLPreviewPanel.shared() else { return }
        if Self.quickLookVisible {
            preview.orderOut(nil)
            return
        }
        quickLook.url = url
        preview.updateController()
        preview.reloadData()
        preview.orderFront(nil)
    }

    /// The selection moved under an open Quick Look: it follows.
    private func updateQuickLook() {
        guard Self.quickLookVisible, let session, let path = session.model.selectedRow?.target?.path else { return }
        quickLook.url = session.project.folderURL.appendingPathComponent(path)
        QLPreviewPanel.shared()?.reloadData()
    }

    // MARK: NSWindowDelegate

    /// A click outside closes the panel; Quick Look coming forward does not.
    func windowDidResignKey(_ notification: Notification) {
        guard let resigned = notification.object as? NSPanel, resigned === panel else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel === resigned, !panel.isKeyWindow, !Self.quickLookVisible else { return }
            center?.dismiss(restoringFocus: false)
        }
    }
}

/// The panel itself: it can be key (the search field) without activating
/// anything, hands key-downs to `keyHandler` first, and is Quick Look's
/// controller while it is key.
final class OpenQuicklyNSPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    private let quickLook: OpenQuicklyQuickLookSource

    init(quickLook: OpenQuicklyQuickLookSource) {
        self.quickLook = quickLook
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = quickLook
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }
}

/// The one file Quick Look shows.
final class OpenQuicklyQuickLookSource: NSObject, QLPreviewPanelDataSource {
    var url: URL?

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL?
    }
}

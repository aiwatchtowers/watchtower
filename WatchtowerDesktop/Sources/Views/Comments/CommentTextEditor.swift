import AppKit
import SwiftUI
import WatchtowerCore

/// The multi-line field every comment is written in (#178): text inset from
/// the border, Return for a new line, ⌘↩ or ⌃↩ to send (`CommentEditorKeys`,
/// only while this field has focus), and — with `focusOnAppear` — the caret
/// already blinking in it when it opens. Grows with its text from
/// `minHeight` to `maxHeight`, then scrolls. A nil `onSubmit` (a draft that
/// is sent with its batch) leaves ⌘↩/⌃↩ to the text view; with
/// `leavesOnSubmit` they leave the field instead (its text is already kept
/// as typed: a margin comment). `onShiftSubmit`, when set, takes ⌘⇧↩/⌃⇧↩
/// from `onSubmit` (an ask's Request changes). `onFocus` runs
/// when the field takes the keyboard or is clicked while it has it (a
/// margin comment's card turning active). Text set through the binding
/// from outside is not undoable (`updateNSView`).
struct CommentTextEditor: View {
    @Binding var text: String
    var placeholder = ""
    var focusOnAppear = false
    var minHeight: CGFloat = 30
    var maxHeight: CGFloat = 120
    var cornerRadius: CGFloat = 6
    var leavesOnSubmit = false
    var onSubmit: (() -> Void)?
    var onShiftSubmit: (() -> Void)?
    var onFocus: (() -> Void)?
    @State private var contentHeight: CGFloat = 0
    @Environment(\.onPopoverSurface) private var onPopoverSurface

    /// A form field's heights (an ask's note, a check item's note, an
    /// "Other…" answer; #394): about three lines from the start, so it
    /// reads as room to write.
    static let formMinHeight: CGFloat = 60
    static let formMaxHeight: CGFloat = 180

    var body: some View {
        CommentNSTextEditor(text: $text, contentHeight: $contentHeight, focusOnAppear: focusOnAppear,
                            leavesOnSubmit: leavesOnSubmit, onSubmit: onSubmit, onShiftSubmit: onShiftSubmit,
                            onFocus: onFocus)
            .frame(height: min(max(contentHeight, minHeight), maxHeight))
            .overlay(alignment: .topLeading) {
                if text.isEmpty, !placeholder.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, CommentNSTextEditor.inset.width + CommentNSTextEditor.linePadding)
                        .padding(.top, CommentNSTextEditor.inset.height)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(wellColor))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
    }

    /// Opaque in a pane; on a popover a translucent well over the material
    /// (#363), still lighter (dark: darker) than it so the text reads.
    private var wellColor: Color {
        Color(nsColor: .textBackgroundColor).opacity(onPopoverSurface ? 0.5 : 1)
    }
}

private struct CommentNSTextEditor: NSViewRepresentable {
    static let inset = NSSize(width: 6, height: 6)
    static let linePadding: CGFloat = 5

    @Binding var text: String
    @Binding var contentHeight: CGFloat
    let focusOnAppear: Bool
    let leavesOnSubmit: Bool
    let onSubmit: (() -> Void)?
    let onShiftSubmit: (() -> Void)?
    let onFocus: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SubmittingTextView(frame: .zero)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = Self.linePadding
        textView.textContainerInset = Self.inset
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.string = text
        textView.delegate = context.coordinator
        textView.focusOnAppear = focusOnAppear
        textView.leavesOnSubmit = leavesOnSubmit
        textView.onSubmit = onSubmit
        textView.onShiftSubmit = onShiftSubmit
        textView.onFocus = onFocus

        // A new width re-wraps the text: measure again.
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.frameDidChange(_:)),
                                               name: NSView.frameDidChangeNotification, object: textView)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        DispatchQueue.main.async { context.coordinator.measure(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? SubmittingTextView else { return }
        textView.leavesOnSubmit = leavesOnSubmit
        textView.onSubmit = onSubmit
        textView.onShiftSubmit = onShiftSubmit
        textView.onFocus = onFocus
        textView.isEditable = context.environment.isEnabled
        if textView.string != text {
            // Text from outside (another ask's draft under the same field,
            // a sent comment cleared) is not an edit: it is not undoable,
            // and the typing undo steps of the text it replaces go with it,
            // so ⌘Z never brings one draft's text into another.
            textView.string = text
            context.coordinator.undoManager.removeAllActions()
            DispatchQueue.main.async { context.coordinator.measure(textView) }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommentNSTextEditor
        /// The field's own undo history (not the window's), so text set
        /// from outside can clear it without touching another field's.
        let undoManager = UndoManager()
        private var measuredWidth: CGFloat?

        init(parent: CommentNSTextEditor) {
            self.parent = parent
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undoManager
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            measure(textView)
        }

        /// A new width re-wraps the text. It arrives mid-layout, so the
        /// height is written on the next turn; height-only changes (typing)
        /// are already measured by `textDidChange`.
        @objc func frameDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, textView.frame.width != measuredWidth else { return }
            measuredWidth = textView.frame.width
            DispatchQueue.main.async { [weak self] in self?.measure(textView) }
        }

        func measure(_ textView: NSTextView) {
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let height = ceil(layout.usedRect(for: container).height + textView.textContainerInset.height * 2)
            if abs(parent.contentHeight - height) > 0.5 { parent.contentHeight = height }
        }
    }
}

/// Sends on ⌘↩/⌃↩ while it is the first responder (or, with
/// `leavesOnSubmit`, resigns it in its own window); everything else —
/// Return included — is ordinary editing. Decided on the key event, not in
/// `doCommandBy` like the chat composer: ⌘↩ arrives as a key equivalent
/// and never as `insertNewline:`, and ⌃↩ arrives as `insertLineBreak:`.
private final class SubmittingTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onShiftSubmit: (() -> Void)?
    var onFocus: (() -> Void)?
    var focusOnAppear = false
    var leavesOnSubmit = false

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        // Not inside AppKit's responder change: the callback writes SwiftUI state.
        if took, let onFocus { DispatchQueue.main.async(execute: onFocus) }
        return took
    }

    /// A click into the field while it already has the keyboard (its card
    /// made inactive by a click elsewhere that took no focus) makes it
    /// active again; `becomeFirstResponder` covers the other clicks.
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder === self, let onFocus { DispatchQueue.main.async(execute: onFocus) }
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAppear, let window else { return }
        focusOnAppear = false
        // Once the popover or sheet has finished presenting.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if submits(event) { submit(event); return }
        super.keyDown(with: event)
    }

    /// ⌘-combinations reach the window as key equivalents before `keyDown`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, submits(event) {
            submit(event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func submit(_ event: NSEvent) {
        let shift = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
        if shift, let onShiftSubmit { onShiftSubmit() } else { onSubmit?() }
        if leavesOnSubmit { window?.makeFirstResponder(nil) }
    }

    private func submits(_ event: NSEvent) -> Bool {
        // Never mid-IME-composition: the Return belongs to the input method.
        guard onSubmit != nil || leavesOnSubmit, event.type == .keyDown, !hasMarkedText() else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return CommentEditorKeys.submits(keyCode: event.keyCode, command: flags.contains(.command),
                                         control: flags.contains(.control))
    }
}

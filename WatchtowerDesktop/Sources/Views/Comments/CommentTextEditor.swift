import AppKit
import SwiftUI
import WatchtowerCore

/// The multi-line field every comment is written in (#178): text inset from
/// the border, Return for a new line, ⌘↩ or ⌃↩ to send (`CommentEditorKeys`,
/// only while this field has focus), and — with `focusOnAppear` — the caret
/// already blinking in it when it opens. Grows with its text from
/// `minHeight` to `maxHeight`, then scrolls. A nil `onSubmit` (a draft that
/// is sent with its batch) leaves ⌘↩/⌃↩ to the text view.
struct CommentTextEditor: View {
    @Binding var text: String
    var placeholder = ""
    var focusOnAppear = false
    var minHeight: CGFloat = 30
    var maxHeight: CGFloat = 120
    var cornerRadius: CGFloat = 6
    var onSubmit: (() -> Void)?
    @State private var contentHeight: CGFloat = 0
    @Environment(\.onPopoverSurface) private var onPopoverSurface

    /// A form field's heights (an ask's note, a check item's note, an
    /// "Other…" answer; #394): about three lines from the start, so it
    /// reads as room to write.
    static let formMinHeight: CGFloat = 60
    static let formMaxHeight: CGFloat = 180

    /// ⌘↩ in a field whose text is already kept as it is typed (an ask's
    /// draft): it leaves the field.
    static func endEditing() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    var body: some View {
        CommentNSTextEditor(text: $text, contentHeight: $contentHeight, focusOnAppear: focusOnAppear, onSubmit: onSubmit)
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
    let onSubmit: (() -> Void)?

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
        textView.onSubmit = onSubmit

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
        textView.onSubmit = onSubmit
        textView.isEditable = context.environment.isEnabled
        if textView.string != text {
            // Through the undoable path: a plain `string =` leaves typing undo
            // steps pointing into the text that was just replaced.
            // The delegate stays out of it: this runs inside a SwiftUI update.
            let all = NSRange(location: 0, length: (textView.string as NSString).length)
            context.coordinator.applyingExternalText = true
            if textView.shouldChangeText(in: all, replacementString: text) {
                textView.replaceCharacters(in: all, with: text)
                textView.didChangeText()
            }
            context.coordinator.applyingExternalText = false
            textView.breakUndoCoalescing()
            DispatchQueue.main.async { context.coordinator.measure(textView) }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommentNSTextEditor
        var applyingExternalText = false
        private var measuredWidth: CGFloat?

        init(parent: CommentNSTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !applyingExternalText, let textView = notification.object as? NSTextView else { return }
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

/// Sends on ⌘↩/⌃↩ while it is the first responder; everything else —
/// Return included — is ordinary editing. Decided on the key event, not in
/// `doCommandBy` like the chat composer: ⌘↩ arrives as a key equivalent
/// and never as `insertNewline:`, and ⌃↩ arrives as `insertLineBreak:`.
private final class SubmittingTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var focusOnAppear = false

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
        if submits(event) { onSubmit?(); return }
        super.keyDown(with: event)
    }

    /// ⌘-combinations reach the window as key equivalents before `keyDown`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, submits(event) {
            onSubmit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func submits(_ event: NSEvent) -> Bool {
        // Never mid-IME-composition: the Return belongs to the input method.
        guard onSubmit != nil, event.type == .keyDown, !hasMarkedText() else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return CommentEditorKeys.submits(keyCode: event.keyCode, command: flags.contains(.command),
                                         control: flags.contains(.control))
    }
}

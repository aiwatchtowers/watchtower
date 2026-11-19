#if os(macOS)
import AppKit
import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// The Mac's text view in the shared composer field (unified chat spec §6.1, D10): Enter sends, Shift+Enter a new
/// line, Esc and ↑ in an empty field go to their closures, ⌘V of an image, a PDF, Finder files or a long text is
/// offered as an attachment, and the `@`/`/` picker gets its keys first. It grows with its text up to `maxHeight`.
struct ChatComposerTextInput: View {
    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    var maxHeight: CGFloat
    var onEscape: (() -> Void)?
    var onArrowUpWhenEmpty: (() -> Void)?
    var onPasteData: ((Data, String) async -> Bool)?
    var onAttachFiles: (([URL]) -> Void)?
    var onLongTextPaste: ((LongPaste) -> Void)?
    var onInlinePaste: ((InlinePaste) async -> String?)?
    var livePastes: [Int: PasteKind] = [:]
    var onCursorChange: ((String, Int) -> Void)?
    var onPickerKey: ((ComposerPickerKey, String, Int) -> ComposerKeyResult)?
    var autoFocus: Bool
    var focusRequest: UUID?
    let onSubmit: () -> Void

    /// The placeholder sits over the text view's first glyph (its line padding plus a point).
    private static let placeholderLeading: CGFloat = 5

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.placeholder)
                    .padding(.leading, Self.placeholderLeading)
                    .padding(.top, Spacing.small)
                    .allowsHitTesting(false)
            }
            ExpandingTextInput(
                text: $text,
                height: $height,
                maxHeight: maxHeight,
                onEscape: onEscape,
                onArrowUpWhenEmpty: onArrowUpWhenEmpty,
                onPasteData: onPasteData,
                onAttachFiles: onAttachFiles,
                onLongTextPaste: onLongTextPaste,
                onInlinePaste: onInlinePaste,
                livePastes: livePastes,
                onCursorChange: onCursorChange,
                onPickerKey: onPickerKey,
                autoFocus: autoFocus,
                focusRequest: focusRequest,
                onSubmit: onSubmit
            )
            .frame(height: height)
        }
        .accessibilityIdentifier("chat.composer.field")
    }
}

// MARK: - Auto-expanding native text input
// Enter sends, Shift+Enter inserts a newline.

public struct ExpandingTextInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var maxHeight: CGFloat = 120
    var onEscape: (() -> Void)?
    var onArrowUpWhenEmpty: (() -> Void)?
    /// A user-initiated paste that `PasteClassifier` turns into an
    /// attachment is consumed here instead of inserted as text. nil → paste
    /// always inserts text, unchanged from before Task 21.
    var onPasteData: ((Data, String) async -> Bool)?
    /// Files copied in Finder (the drop/paperclip path).
    var onAttachFiles: (([URL]) -> Void)?
    /// A long text paste, after it was inserted: the inserted text.
    var onLongTextPaste: ((LongPaste) -> Void)?
    /// Set: a pasted image or long text goes in as the token it returns (#2065 §6, `ComposerPasteRoute`).
    var onInlinePaste: ((InlinePaste) async -> String?)?
    /// The kind of each token number with a payload: one Backspace removes such a token whole.
    var livePastes: [Int: PasteKind] = [:]
    /// The @/ pickers' input (Task 25/26): full text + caret on every change.
    var onCursorChange: ((String, Int) -> Void)?
    /// Offered Up/Down/Enter/Tab/Esc first while a picker may be open.
    var onPickerKey: ((ComposerPickerKey, String, Int) -> ComposerKeyResult)?
    /// Makes the text view first responder once it is in its window.
    var autoFocus = false
    /// Each new value makes the text view first responder, caret at the end.
    var focusRequest: UUID?
    var onSubmit: () -> Void

    private let minHeight: CGFloat = 20

    public init(
        text: Binding<String>,
        height: Binding<CGFloat>,
        maxHeight: CGFloat = 120,
        onEscape: (() -> Void)? = nil,
        onArrowUpWhenEmpty: (() -> Void)? = nil,
        onPasteData: ((Data, String) async -> Bool)? = nil,
        onAttachFiles: (([URL]) -> Void)? = nil,
        onLongTextPaste: ((LongPaste) -> Void)? = nil,
        onInlinePaste: ((InlinePaste) async -> String?)? = nil,
        livePastes: [Int: PasteKind] = [:],
        onCursorChange: ((String, Int) -> Void)? = nil,
        onPickerKey: ((ComposerPickerKey, String, Int) -> ComposerKeyResult)? = nil,
        autoFocus: Bool = false,
        focusRequest: UUID? = nil,
        onSubmit: @escaping () -> Void
    ) {
        _text = text
        _height = height
        self.maxHeight = maxHeight
        self.onEscape = onEscape
        self.onArrowUpWhenEmpty = onArrowUpWhenEmpty
        self.onPasteData = onPasteData
        self.onAttachFiles = onAttachFiles
        self.onLongTextPaste = onLongTextPaste
        self.onInlinePaste = onInlinePaste
        self.livePastes = livePastes
        self.onCursorChange = onCursorChange
        self.onPickerKey = onPickerKey
        self.autoFocus = autoFocus
        self.focusRequest = focusRequest
        self.onSubmit = onSubmit
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = PastingTextView(frame: .zero)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 4
        textView.drawsBackground = false
        textView.onPasteData = onPasteData
        textView.onAttachFiles = onAttachFiles
        textView.onLongTextPaste = onLongTextPaste
        textView.onInlinePaste = onInlinePaste
        textView.livePastes = livePastes

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.frameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: textView
        )

        if autoFocus { Self.focus(textView) }
        return scrollView
    }

    /// Next run-loop turn (the view is in its window by then): first
    /// responder, caret at the end.
    private static func focus(_ textView: NSTextView) {
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        }
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? PastingTextView else { return }
        textView.onPasteData = onPasteData
        textView.onAttachFiles = onAttachFiles
        textView.onLongTextPaste = onLongTextPaste
        textView.onInlinePaste = onInlinePaste
        textView.livePastes = livePastes
        if textView.string != text {
            textView.string = text
            DispatchQueue.main.async {
                context.coordinator.recalculateHeight(textView)
            }
        }
        if focusRequest != context.coordinator.focusRequest {
            context.coordinator.focusRequest = focusRequest
            if focusRequest != nil { Self.focus(textView) }
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ExpandingTextInput
        /// The last `focusRequest` seen: only one made after the field
        /// appeared moves the keyboard.
        var focusRequest: UUID?

        init(_ parent: ExpandingTextInput) {
            self.parent = parent
            focusRequest = parent.focusRequest
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            recalculateHeight(textView)
        }

        /// The @/ pickers' input. Guarded against IME composition (`hasMarkedText`)
        /// so an in-progress Chinese/Japanese/Korean candidate never opens or
        /// updates a picker — the caret/selection AppKit reports mid-composition
        /// is the composition's own, not a finished `@`/`/` trigger.
        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, !textView.hasMarkedText() else { return }
            parent.onCursorChange?(textView.string, textView.selectedRange().location)
        }

        /// Up/Down/Enter/Tab/Esc while a picker may be open (Task 25/26).
        private static func pickerKey(for selector: Selector) -> ComposerPickerKey? {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): return .up
            case #selector(NSResponder.moveDown(_:)): return .down
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): return .accept
            case #selector(NSResponder.cancelOperation(_:)): return .dismiss
            default: return nil
            }
        }

        private func apply(_ edit: ComposerEdit, to textView: NSTextView) {
            textView.string = edit.text
            textView.setSelectedRange(NSRange(location: edit.cursor, length: 0))
            parent.text = edit.text
            recalculateHeight(textView)
            parent.onCursorChange?(edit.text, edit.cursor)
        }

        public func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            // A command selector fired mid-IME-composition would confirm or
            // discard the composition out from under the input method —
            // never intercept one (controller note: IME must not trigger the
            // picker or send).
            guard !textView.hasMarkedText() else { return false }
            if let handler = parent.onPickerKey, let key = Self.pickerKey(for: sel) {
                let result = handler(key, textView.string, textView.selectedRange().location)
                if let edit = result.edit { apply(edit, to: textView) }
                if result.consumed { return true }
            }
            if sel == #selector(NSResponder.insertNewline(_:)) {
                let event = NSApp.currentEvent
                if event?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                // Plain Enter → send
                parent.onSubmit()
                return true
            }
            if sel == #selector(NSResponder.cancelOperation(_:)), let onEscape = parent.onEscape {
                onEscape()
                return true
            }
            if sel == #selector(NSResponder.moveUp(_:)), textView.string.isEmpty, let up = parent.onArrowUpWhenEmpty {
                up()
                return true
            }
            return false
        }

        func recalculateHeight(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let inset = textView.textContainerInset
            let newHeight = usedRect.height + inset.height * 2
            let clamped = min(max(newHeight, parent.minHeight), parent.maxHeight)
            if abs(parent.height - clamped) > 0.5 {
                parent.height = clamped
            }
        }

        @objc func frameDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            recalculateHeight(textView)
        }
    }
}
#endif

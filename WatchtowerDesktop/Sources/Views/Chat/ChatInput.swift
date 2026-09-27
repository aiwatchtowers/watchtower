import SwiftUI
import AppKit
import WatchtowerCore

struct ChatInput: View {
    @Binding var text: String
    let isStreaming: Bool
    let onSend: () -> Void
    var onStop: (() -> Void)?
    var placeholder: String = "Ask about your workspace..."
    /// nil → no mic button (the defaulted-member precedent, so no call site breaks).
    var dictationTargetID: String?
    /// Main-chat composer grows to ~40% of the window; Discuss chats keep 120.
    var maxHeight: CGFloat = 120
    var onEscape: (() -> Void)?
    /// ↑ in an empty field (main chat: edit the last message).
    var onArrowUpWhenEmpty: (() -> Void)?
    /// Every attachment param defaults to inert (nil closures, empty array),
    /// so a Discuss chat that never wires attachments renders no paperclip
    /// and accepts no drop/paste — the pre-Task-21 behavior, unchanged.
    var attachments: [ChatAttachment] = []
    var attachmentError: String?
    var onAttachFiles: (([URL]) -> Void)?
    var onPasteImage: ((Data) -> Void)?
    var onRemoveAttachment: ((Int64) -> Void)?
    /// Called with the full text and the caret (UTF-16 offset) on every edit
    /// or caret move — the @/ pickers' input. nil for a surface with no
    /// picker (the Discuss-chat default).
    var onCursorChange: ((String, Int) -> Void)?
    /// Offered Up/Down/Enter/Tab/Esc first while a picker may be open;
    /// `consumed == false` falls through to the normal handling (Enter
    /// sends, Esc stops).
    var onPickerKey: ((ComposerPickerKey, String, Int) -> ComposerKeyResult)?
    @Environment(\.dictationCenter) private var dictationCenter

    var body: some View {
        ChatInputContent(
            text: $text,
            isStreaming: isStreaming,
            onSend: onSend,
            onStop: onStop,
            placeholder: placeholder,
            dictationTargetID: dictationTargetID,
            dictationCenter: dictationCenter,
            maxHeight: maxHeight,
            onEscape: onEscape,
            onArrowUpWhenEmpty: onArrowUpWhenEmpty,
            attachments: attachments,
            attachmentError: attachmentError,
            onAttachFiles: onAttachFiles,
            onPasteImage: onPasteImage,
            onRemoveAttachment: onRemoveAttachment,
            onCursorChange: onCursorChange,
            onPickerKey: onPickerKey
        )
    }
}

/// The input row's actual rendering, split from `ChatInput` so it reads no
/// custom `@Environment` — ViewInspector cannot resolve those without a real
/// render pass (the `TrayMenuView`/`TrayMenuContent` precedent); tests drive
/// this view with an explicit center.
struct ChatInputContent: View {
    @Binding var text: String
    let isStreaming: Bool
    let onSend: () -> Void
    var onStop: (() -> Void)?
    var placeholder: String
    var dictationTargetID: String?
    var dictationCenter: DictationCenter?
    var maxHeight: CGFloat = 120
    var onEscape: (() -> Void)?
    var onArrowUpWhenEmpty: (() -> Void)?
    var attachments: [ChatAttachment] = []
    var attachmentError: String?
    var onAttachFiles: (([URL]) -> Void)?
    var onPasteImage: ((Data) -> Void)?
    var onRemoveAttachment: ((Int64) -> Void)?
    var onCursorChange: ((String, Int) -> Void)?
    var onPickerKey: ((ComposerPickerKey, String, Int) -> ComposerKeyResult)?
    @State private var inputHeight: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let attachmentError {
                Text(attachmentError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }
            if !attachments.isEmpty {
                AttachmentChipsView(attachments: attachments, onRemove: onRemoveAttachment)
                    .padding(.horizontal, 12)
            }
            row
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let onAttachFiles else { return false }
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            onAttachFiles(files)
            return true
        }
    }

    private var row: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if let onAttachFiles {
                Button {
                    pickFiles(onAttachFiles)
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Attach files")
                .help("Attach images, PDFs or text files")
                .padding(.bottom, 6)
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.placeholder)
                        .padding(.leading, 5)
                        .padding(.top, 4)
                        .allowsHitTesting(false)
                }

                ExpandingTextInput(
                    text: $text,
                    height: $inputHeight,
                    maxHeight: maxHeight,
                    onEscape: onEscape,
                    onArrowUpWhenEmpty: onArrowUpWhenEmpty,
                    onPasteImage: onPasteImage,
                    onCursorChange: onCursorChange,
                    onPickerKey: onPickerKey
                ) {
                    guard canSend else { return }
                    onSend()
                }
                .frame(height: inputHeight)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color(.separatorColor).opacity(0.3), lineWidth: 0.5)
            )
            // "" is a sentinel for a nil dictationTargetID: it never matches a
            // real activeTargetID, so a mic-less input never lights up.
            .dictationHighlight(targetID: dictationTargetID ?? "", center: dictationCenter, cornerRadius: 18)

            if let id = dictationTargetID, let center = dictationCenter {
                DictationButton(text: $text, mode: .chat, targetID: id, center: center)
            }

            Button {
                if isStreaming {
                    onStop?()
                } else {
                    onSend()
                }
            } label: {
                Image(systemName: isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(buttonActive ? Color.accentColor : Color(.tertiaryLabelColor))
            }
            .buttonStyle(.borderless)
            .disabled(!buttonActive)
            .accessibilityLabel(isStreaming ? "Stop" : "Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func pickFiles(_ onAttachFiles: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Attach images, PDFs or text files"
        panel.begin { response in
            guard response == .OK else { return }
            onAttachFiles(panel.urls)
        }
    }

    /// A message may carry only attachments (no text).
    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var buttonActive: Bool {
        isStreaming ? onStop != nil : canSend
    }
}

// MARK: - Auto-expanding native text input
// Enter sends, Shift+Enter inserts a newline.

struct ExpandingTextInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var maxHeight: CGFloat = 120
    var onEscape: (() -> Void)?
    var onArrowUpWhenEmpty: (() -> Void)?
    /// A user-initiated paste of an image-only pasteboard: consumed here
    /// instead of inserted as text. nil → paste always inserts text (or is a
    /// no-op for an image-only pasteboard), unchanged from before Task 21.
    var onPasteImage: ((Data) -> Void)?
    /// The @/ pickers' input (Task 25/26): full text + caret on every change.
    var onCursorChange: ((String, Int) -> Void)?
    /// Offered Up/Down/Enter/Tab/Esc first while a picker may be open.
    var onPickerKey: ((ComposerPickerKey, String, Int) -> ComposerKeyResult)?
    var onSubmit: () -> Void

    private let minHeight: CGFloat = 20

    func makeNSView(context: Context) -> NSScrollView {
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
        textView.onPasteImage = onPasteImage

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

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? PastingTextView else { return }
        textView.onPasteImage = onPasteImage
        if textView.string != text {
            textView.string = text
            DispatchQueue.main.async {
                context.coordinator.recalculateHeight(textView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ExpandingTextInput

        init(_ parent: ExpandingTextInput) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            recalculateHeight(textView)
        }

        /// The @/ pickers' input. Guarded against IME composition (`hasMarkedText`)
        /// so an in-progress Chinese/Japanese/Korean candidate never opens or
        /// updates a picker — the caret/selection AppKit reports mid-composition
        /// is the composition's own, not a finished `@`/`/` trigger.
        func textViewDidChangeSelection(_ notification: Notification) {
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

        func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
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

/// Intercepts an image-only paste (Task 21 / preflight A40): text pastes and
/// mixed pasteboards fall through to the normal insert.
private final class PastingTextView: NSTextView {
    var onPasteImage: ((Data) -> Void)?

    override func paste(_ sender: Any?) {
        if let onPasteImage, let png = PastedImage.pngData(from: .general) {
            onPasteImage(png)
            return
        }
        super.paste(sender)
    }
}

#if os(iOS)
import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// The phone's text field in the shared composer field: it grows with its text; the caret is taken as the end of
/// the text (the `@`/`/` picker reads the query before it). Return adds a line; Send sends.
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
    /// The Mac's inline paste tokens (#2065 §6); the phone has none.
    var onInlinePaste: ((InlinePaste) async -> String?)?
    var livePastes: [Int: PasteKind] = [:]
    var onCursorChange: ((String, Int) -> Void)?
    var onPickerKey: ((ComposerPickerKey, String, Int) -> ComposerKeyResult)?
    /// The Mac's ⌥↓; the phone has no arrow keys.
    var onOptionArrowDown: (() -> Bool)?
    var autoFocus: Bool
    var focusRequest: UUID?
    let onSubmit: () -> Void

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1...6)
            .font(.body)
            .onChange(of: text) { _, new in onCursorChange?(new, new.utf16.count) }
            .accessibilityIdentifier("chat.composer.field")
    }
}
#endif

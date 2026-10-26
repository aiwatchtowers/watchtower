import SwiftUI
import AppKit

/// Plain text field that reliably handles focus on macOS.
/// Looks like SwiftUI TextField(.plain) but uses NSTextField for proper first responder.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Search"
    /// Told when the field takes and leaves the keyboard; nil = not watched.
    var onFocusChange: ((Bool) -> Void)?

    func makeNSView(context: Context) -> PlainTextField {
        let field = PlainTextField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.onBecomeFirstResponder = { [weak coordinator = context.coordinator] in coordinator?.focusChanged(true) }
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        return field
    }

    func updateNSView(_ nsView: PlainTextField, context: Context) {
        context.coordinator.onFocusChange = onFocusChange
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onFocusChange: onFocusChange)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onFocusChange: ((Bool) -> Void)?

        init(text: Binding<String>, onFocusChange: ((Bool) -> Void)? = nil) {
            self.text = text
            self.onFocusChange = onFocusChange
        }

        func focusChanged(_ focused: Bool) {
            onFocusChange?(focused)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            focusChanged(false)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

class PlainTextField: NSTextField {
    /// Called once the field took the keyboard (its editor is in place).
    var onBecomeFirstResponder: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onBecomeFirstResponder?() }
        return became
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

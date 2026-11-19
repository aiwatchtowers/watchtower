#if os(iOS)
import SwiftUI
import UIKit
import WatchtowerChatText
import WatchtowerDesign

/// The phone's quote: a sheet with the answer as selectable text; the owner selects the passage to ask about (the
/// Mac quotes from a selection in the feed, `ChatSelectionQuote`).
public struct PassagePickerSheet: View {
    public static let hint = "Select the part you want to ask about."
    public static let askLabel = "Ask about this"
    public static let cancelLabel = "Cancel"

    let text: String
    let pick: (String) -> Void
    @State private var selection: String?
    @Environment(\.dismiss) private var dismiss

    public init(text: String, pick: @escaping (String) -> Void) {
        self.text = text
        self.pick = pick
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                Text(Self.hint).font(.caption).foregroundStyle(.secondary).padding(.horizontal, Spacing.large)
                SelectableText(text: text, selection: $selection)
            }
            .navigationTitle(Self.askLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Self.askLabel) {
                        if let selection { pick(selection) }
                        dismiss()
                    }
                    .disabled(selection == nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(Self.cancelLabel) { dismiss() }
                }
            }
        }
    }
}

private struct SelectableText: UIViewRepresentable {
    let text: String
    @Binding var selection: String?

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .callout)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: Spacing.regular, left: Spacing.medium, bottom: Spacing.regular, right: Spacing.medium)
        view.backgroundColor = .clear
        view.delegate = context.coordinator
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let selection: Binding<String?>

        init(selection: Binding<String?>) {
            self.selection = selection
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            selection.wrappedValue = ChatQuoteReply.selectedText(textView.text, selection: textView.selectedRange)
        }
    }
}
#endif

import AppKit
import SwiftUI
import WatchtowerCore

/// "Quote in reply" on an assistant answer: the answer as selectable text in
/// a sheet — the chat's only text view, alive only while the owner quotes;
/// thread rows keep rendering with `MarkdownView`. "Add to reply" hands the
/// selection and the owner's comment to the pending batch; nothing is sent
/// or stored here.
struct QuoteReplySheet: View {
    let onAdd: (_ quote: String, _ comment: String) -> Void
    private let rendered: RenderedDocument
    /// Built once: a stable instance lets `DocumentTextView` skip re-applying
    /// its text on every re-render, so the owner's selection is kept.
    private let attributed: NSAttributedString
    @Environment(\.dismiss) private var dismiss
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var comment = ""

    init(messageText: String, onAdd: @escaping (_ quote: String, _ comment: String) -> Void) {
        let rendered = DocumentRendering.render(ChatQuoteReply.quotableMarkdown(messageText))
        self.rendered = rendered
        attributed = DocumentAttributedString.make(rendered, highlights: [:], activeThreadID: nil)
        self.onAdd = onAdd
    }

    private var quote: String? { ChatQuoteReply.selectedText(rendered.text, selection: selection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Select the part to quote").font(.headline)
            DocumentTextView(text: attributed, contentID: "quote", selection: $selection) { _ in }
                .frame(minHeight: 240)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            if let quote {
                Text("\u{201C}\(quote)\u{201D}")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            TextField("Your comment on the quote (optional)", text: $comment, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
            Text("Quotes collect above the message box and go out together when you send.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to reply") {
                    guard let quote else { return }
                    onAdd(quote, comment)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(quote == nil)
            }
        }
        .padding(16)
        .frame(width: 600, height: 500)
    }
}

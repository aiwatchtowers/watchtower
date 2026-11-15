import SwiftUI
import UIKit
import WatchtowerKit

/// A review (#1787): the snapshot reads full width in the screen's own
/// scroll, one paragraph per line of the rendered text (no nested box);
/// press and hold a paragraph to comment on it, and the comment shows under
/// it. A cut snapshot says so above the text and where it stops. The note
/// and Approve / Request changes live in the bottom bar (`AskView`).
struct ReviewAskView: View {
    let review: AskFormModel.Review
    /// The Mac reviewer's state; nil from an older Mac or a non-spec document.
    var specReview: OwnerAsk.SpecReviewLine?
    let model: AskViewModel
    let isEditable: Bool
    @State private var composing: ReviewParagraph?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            header
            if review.document != nil {
                LazyVStack(alignment: .leading, spacing: Spacing.regular) {
                    ForEach(review.paragraphs) { paragraph in
                        paragraphBlock(paragraph)
                    }
                }
            }
            if let end = review.clippedEnd {
                Label(end, systemImage: "desktopcomputer")
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .card(.plain)
            }
            if !review.unplacedComments.isEmpty {
                SectionHeader("Your comments", count: review.unplacedComments.count)
                ForEach(review.unplacedComments) { commentCard($0) }
            }
            if let verdict = review.verdict {
                Text(verdict == .approved ? "Your verdict: approve" : "Your verdict: changes requested")
                    .font(TypeScale.rowTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $composing) { paragraph in
            ReviewCommentSheet(paragraph: paragraph, review: review, model: model) { composing = nil }
        }
    }

    /// The path, the Mac reviewer's line, the cut notice and the comment hint.
    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(review.docPath).font(TypeScale.code).foregroundStyle(.secondary)
            if let specReview, !specReview.line.isEmpty {
                Label(specReview.line, systemImage: "checklist")
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(specReview.line)
            }
            if let clipped = review.clippedNotice {
                Text(clipped).font(TypeScale.meta).foregroundStyle(.secondary)
            }
            Text(review.commentsLine).font(TypeScale.meta).foregroundStyle(.secondary)
        }
    }

    private func paragraphBlock(_ paragraph: ReviewParagraph) -> some View {
        let comments = review.commentsByParagraph[paragraph.id] ?? []
        return VStack(alignment: .leading, spacing: Spacing.regular) {
            paragraphText(paragraph)
                .padding(.leading, comments.isEmpty ? 0 : Spacing.regular)
                .overlay(alignment: .leading) {
                    if !comments.isEmpty {
                        Capsule().fill(PhoneTone.accent.color).frame(width: Spacing.tight)
                    }
                }
                .contentShape(Rectangle())
                .contextMenu {
                    if isEditable {
                        Button { composing = paragraph } label: { Label(AskText.comment, systemImage: "text.bubble") }
                    }
                    Button { UIPasteboard.general.string = paragraph.text } label: { Label(AskText.copy, systemImage: "doc.on.doc") }
                }
                .accessibilityAction(named: AskText.comment) { if isEditable { composing = paragraph } }
            // The paragraph is right above: a whole-paragraph quote is not repeated.
            ForEach(comments) { commentCard($0, showQuote: $0.quote != paragraph.text) }
        }
    }

    @ViewBuilder
    private func paragraphText(_ paragraph: ReviewParagraph) -> some View {
        if let level = paragraph.headingLevel {
            Text(paragraph.text)
                .font(Self.headingFont(level))
                .padding(.top, Spacing.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if let marker = paragraph.marker {
                    Text(marker).foregroundStyle(.secondary)
                }
                Text(paragraph.text)
            }
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    /// Level 1 title2, level 2 title3, deeper headline; all semibold.
    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: TypeScale.pageTitle
        case 2: TypeScale.screenTitle
        default: Font.headline
        }
    }

    private func commentCard(_ comment: AskFormModel.Comment, showQuote: Bool = true) -> some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                if showQuote {
                    Text("“\(comment.quote)”")
                        .font(TypeScale.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                SheetField(label: "Your comment") {
                    TextField("Your comment", text: bodyBinding(comment.id), axis: .vertical)
                        .lineLimit(1...6)
                        .disabled(!isEditable)
                }
            }
            if isEditable {
                Button(role: .destructive) {
                    model.removeComment(comment.id)
                } label: {
                    Image(systemName: "trash")
                        .frame(width: PhoneMetrics.minTouch, height: PhoneMetrics.minTouch)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Delete comment")
            }
        }
        .card(.plain)
    }

    private func bodyBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { model.draft.comments.first { $0.id == id }?.body ?? "" },
            set: { model.setCommentBody($0, for: id) }
        )
    }
}

/// The comment on one paragraph: the paragraph selectable (a selection
/// narrows the quote to it; none keeps the whole paragraph), then the
/// comment, Cancel and Add.
private struct ReviewCommentSheet: View {
    let paragraph: ReviewParagraph
    let review: AskFormModel.Review
    let model: AskViewModel
    let close: () -> Void
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var text = ""

    /// The quoted range in the document: the selection, or the paragraph.
    private var quoted: NSRange {
        selection.length > 0 ? NSRange(location: paragraph.range.location + selection.location, length: selection.length) : paragraph.range
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ParagraphSelectView(text: paragraph.text, selection: $selection)
                        .frame(minHeight: PhoneMetrics.minTouch * 2)
                        .accessibilityLabel("Paragraph to comment on")
                } header: {
                    Text("On")
                } footer: {
                    Text(AskText.commentSheetHint)
                }
                Section("Comment") {
                    TextField("Your comment", text: $text, axis: .vertical).lineLimit(3...10)
                }
            }
            .navigationTitle(AskText.comment)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let document = review.document {
                            model.addComment(on: quoted, in: document, body: text)
                        }
                        close()
                    }
                    .disabled(AskDraft.trimmed(text).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// One paragraph as read-only selectable text; reports the selection in
/// UTF-16 units of `text`.
private struct ParagraphSelectView: UIViewRepresentable {
    let text: String
    @Binding var selection: NSRange

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.adjustsFontForContentSizeCategory = true
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = .label
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.text = text
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let selection: Binding<NSRange>

        init(selection: Binding<NSRange>) {
            self.selection = selection
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            selection.wrappedValue = textView.selectedRange
        }
    }
}

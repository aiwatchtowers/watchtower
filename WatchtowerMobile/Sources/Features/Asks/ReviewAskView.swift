import SwiftUI
import UIKit
import WatchtowerKit

/// A review: the snapshot as the plain text the anchors index (so a
/// selection is an anchor), "Showing the first 256 KB of N" when the hub
/// cut it, the margin comments, and Approve / Request changes (the send
/// bar). Comments go only on shown text; without a snapshot there is
/// nothing to select.
struct ReviewAskView: View {
    let review: AskFormModel.Review
    /// The Mac reviewer's state; nil from an older Mac or a non-spec document.
    var specReview: OwnerAsk.SpecReviewLine?
    let model: AskViewModel
    let isEditable: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var composing: NSRange?
    @State private var commentText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            documentCard
            if !review.comments.isEmpty {
                SectionHeader("Your comments", count: review.comments.count)
                ForEach(review.comments) { comment in
                    commentCard(comment)
                }
            }
            if let verdict = review.verdict {
                Text(verdict == .approved ? "Your verdict: approve" : "Your verdict: changes requested")
                    .font(TypeScale.rowTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: Binding(get: { composing.map(SelectionBox.init) }, set: { composing = $0?.range })) { box in
            commentSheet(box.range)
        }
        // A new document (a newer round) never keeps the old selection.
        .onChange(of: review.document?.text) { selection = NSRange(location: 0, length: 0) }
    }

    /// The document reads full width on a card (mockup 10); the path above.
    private var documentCard: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(review.docPath).font(TypeScale.code).foregroundStyle(.secondary)
            if let specReview, !specReview.line.isEmpty {
                Label(specReview.line, systemImage: "checklist")
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(specReview.line)
            }
            if let document = review.document {
                SnapshotTextView(document: document, category: UIContentSizeCategory(dynamicTypeSize), selection: $selection)
                    .frame(minHeight: PhoneMetrics.documentHeight.lowerBound, maxHeight: PhoneMetrics.documentHeight.upperBound)
                    .accessibilityLabel("Document under review")
                if let clipped = review.clippedNotice {
                    Text(clipped).font(TypeScale.meta).foregroundStyle(.secondary)
                }
                Button {
                    commentText = ""
                    composing = selection
                } label: {
                    Label("Comment on the selection", systemImage: "text.bubble")
                }
                .buttonStyle(SecondaryActionStyle())
                .disabled(!isEditable || selection.length == 0)
            }
            Text(review.commentsLine).font(TypeScale.meta).foregroundStyle(.secondary)
        }
        .card(.plain)
    }

    private func commentCard(_ comment: AskFormModel.Comment) -> some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                Text("“\(comment.quote)”")
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
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

    private func commentSheet(_ range: NSRange) -> some View {
        NavigationStack {
            Form {
                if let document = review.document, let quote = Range(range, in: document.text).map({ String(document.text[$0]) }) {
                    Section("On") { Text("“\(quote)”").foregroundStyle(.secondary).lineLimit(4) }
                }
                Section("Comment") {
                    TextField("Your comment", text: $commentText, axis: .vertical).lineLimit(3...10)
                }
            }
            .navigationTitle("Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { composing = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let document = review.document {
                            model.addComment(on: range, in: document, body: commentText)
                        }
                        composing = nil
                    }
                    .disabled(AskDraft.trimmed(commentText).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func bodyBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { model.draft.comments.first { $0.id == id }?.body ?? "" },
            set: { model.setCommentBody($0, for: id) }
        )
    }
}

/// A selection to comment on, as a sheet item.
private struct SelectionBox: Identifiable {
    let range: NSRange
    var id: String { "\(range.location):\(range.length)" }
}

/// The snapshot as a styled, read-only, selectable document; reports the
/// selection in UTF-16 units of `document.text` (the anchors' offsets).
private struct SnapshotTextView: UIViewRepresentable {
    let document: PlainTextDocument
    /// The Dynamic Type size to style at; a change restyles the same text.
    let category: UIContentSizeCategory
    @Binding var selection: NSRange

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        guard ReviewDocumentStyler.needsRestyle(
            shown: view.attributedText.string, styledCategory: coordinator.styledCategory, document: document, category: category
        ) else { return }
        // A size change keeps the text, so it keeps the selection. While
        // restyling, the delegate ignores the programmatic selection change,
        // so nothing writes the binding during this view update. The string
        // is `document.text` itself, so selections stay UTF-16 offsets into it.
        let kept = view.attributedText.string == document.text ? view.selectedRange : nil
        coordinator.isRestyling = true
        let traits = view.traitCollection.modifyingTraits { $0.preferredContentSizeCategory = category }
        view.attributedText = ReviewDocumentStyler.attributed(document, traits: traits)
        if let kept {
            view.selectedRange = kept
        }
        coordinator.isRestyling = false
        coordinator.styledCategory = category
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let selection: Binding<NSRange>
        /// The size the shown text was styled at; nil before the first style.
        var styledCategory: UIContentSizeCategory?
        var isRestyling = false

        init(selection: Binding<NSRange>) {
            self.selection = selection
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isRestyling else { return }
            selection.wrappedValue = textView.selectedRange
        }
    }
}

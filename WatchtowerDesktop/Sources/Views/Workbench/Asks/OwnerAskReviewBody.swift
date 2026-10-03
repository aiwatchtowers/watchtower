import SwiftUI
import WatchtowerCore

/// A review ask's document (spec 2026-10-03 Part 8): the agent's
/// `doc_snapshot` rendered with `ReviewTypography` in a centered column,
/// selectable for margin comments (`CommentableDocumentText`), the comments
/// beside it (`OwnerAskMarginComments`, no margin without any) and a bar on
/// the left of every focus item's place. Comments anchor on the snapshot,
/// never on the live file (Part 10). A closed ask shows its stored
/// comments, read-only.
///
/// The snapshot is rendered off the main actor and its places located once
/// per ask (`OwnerAskReviewDocuments`). Its attributed text depends on the
/// snapshot alone: comment highlights are drawn over it
/// (`DocumentTextView.highlightRanges`), so adding, removing or typing a
/// comment never re-sets or re-lays out the text; boxes are measured only
/// on text already laid out (`DocumentTextView.Coordinator.visibleRects`).
struct OwnerAskReviewBody: View {
    let asks: OwnerAsksViewModel
    let ask: OwnerAsk
    /// Comments are added and edited only while the ask is open and no
    /// answer is being written.
    let editable: Bool
    var scrollTarget: DocumentScrollTarget?

    @State private var selection = DocumentSelectionCarry.none
    @State private var composerText = ""
    @State private var rects: [NSRange: CGRect] = [:]
    @State private var extent: CGRect?
    @State private var activeComment: String?

    private var documents: OwnerAskReviewDocuments { asks.reviewDocuments }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !ask.docPath.isEmpty {
                Label(ask.docPath, systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            if let doc = documents.rendered[ask.id] {
                document(doc)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: ask.id) { await documents.prepare(ask) }
        // A selection belongs to one snapshot.
        .onChange(of: ask.id) { _, _ in
            selection = DocumentSelectionCarry.none
            activeComment = nil
            rects = [:]
            extent = nil
        }
    }

    /// A closed ask's stored comments; else the draft's.
    private var comments: [(anchor: CommentAnchor, body: String, id: String, draftID: UUID?)] {
        if let answer = ask.answer {
            return answer.comments.enumerated().map { index, comment in
                (OwnerAskReviewText.anchor(of: comment), comment.body, "answer-\(index)", nil)
            }
        }
        return asks.drafts.draft(for: ask.id).comments.map { ($0.anchor, $0.body, $0.id.uuidString, editable ? $0.id : nil) }
    }

    private func document(_ doc: RenderedDocument) -> some View {
        let askID = ask.id
        let items = comments
        let ranges = items.map { documents.range(of: $0.anchor, askID: askID) }
        let margin = items.enumerated().map { index, item in
            OwnerAskMarginComment(id: item.id, draftID: item.draftID, anchor: item.anchor, body: item.body,
                                  placed: ranges[index] != nil)
        }
        let focus = ask.payload.focus.compactMap { documents.range(of: $0, askID: askID) }
        let placed = ranges.compactMap(\.self)
        let text = DocumentAttributedString.make(doc, highlights: [:], activeThreadID: nil, typography: ReviewTypography.style)
        return GeometryReader { geo in
            let marginWidth = OwnerAskMarginLayout.width(total: geo.size.width, comments: margin.count)
            let textWidth = geo.size.width - marginWidth
            let inset = ReviewTypography.horizontalInset(forWidth: textWidth)
            HStack(spacing: 0) {
                CommentableDocumentText(
                    text: text,
                    contentID: "owner-ask/\(askID)",
                    selection: $selection,
                    composerText: $composerText,
                    horizontalInset: inset,
                    scrollTarget: scrollTarget,
                    trackedRanges: placed + focus,
                    trackedRects: $rects,
                    textExtent: $extent,
                    highlightRanges: placed,
                    onComment: editable ? { body, range in addComment(body, on: range, in: doc) } : nil
                ) { location in
                    // A click on a highlight picks its comment.
                    guard let index = ranges.firstIndex(where: { $0.map { NSLocationInRange(location, $0) } ?? false })
                    else { return }
                    activeComment = margin[index].id
                }
                // Boxes are looked up by the range they were measured for:
                // a pass before the next report shows nothing, never a
                // box of another passage.
                .overlay(alignment: .topLeading) { focusBars(focus.map { rects[$0] }, x: inset - 10) }
                .frame(width: textWidth)
                if marginWidth > 0 {
                    OwnerAskMarginComments(
                        comments: margin,
                        rects: ranges.map { $0.flatMap { rects[$0] } },
                        textExtent: extent,
                        active: $activeComment,
                        setBody: { id, body in setBody(body, of: id) },
                        remove: remove
                    )
                    .frame(width: marginWidth)
                }
            }
        }
    }

    /// A bar on the left of the column beside each focus item's place.
    private func focusBars(_ rects: [CGRect?], x: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
                if let rect {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.orange.opacity(0.8))
                        .frame(width: 3, height: rect.height)
                        .offset(x: x, y: rect.minY)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func addComment(_ body: String, on range: NSRange, in doc: RenderedDocument) -> Bool {
        guard let anchor = OwnerAskReviewText.anchor(selection: range, in: doc) else { return false }
        let comment = OwnerAskCommentDraft(anchor: anchor, body: body)
        guard asks.editDraft(ask.id, { $0.comments.append(comment) }) else { return false }
        documents.remember(anchor, at: range, askID: ask.id)
        activeComment = comment.id.uuidString
        return true
    }

    private func setBody(_ body: String, of id: UUID) {
        asks.editDraft(ask.id) { draft in
            guard let index = draft.comments.firstIndex(where: { $0.id == id }) else { return }
            draft.comments[index].body = body
        }
    }

    private func remove(_ id: UUID) {
        asks.editDraft(ask.id) { $0.comments.removeAll { $0.id == id } }
    }
}

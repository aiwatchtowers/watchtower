import SwiftUI
import WatchtowerCore

/// One unsent draft in the threads panel: its passage, its editable text and
/// Delete. A draft whose passage left the document is kept but not sent.
struct WorkbenchCommentDraftRow: View {
    let draft: WorkbenchCommentDraft
    let located: Bool
    let sending: Bool
    let onEdit: (String) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\u{201C}\(draft.anchor.quote)\u{201D}")
                .font(.caption)
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(3)
            // No ⌘↩ here: a draft is sent with its batch (Send N comments).
            CommentTextEditor(text: Binding(get: { draft.body }, set: onEdit), placeholder: "Comment")
            HStack {
                if let note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        // A send in flight writes this text: an edit now would be lost.
        .disabled(sending)
    }

    /// Why Send leaves this draft behind, if it does.
    private var note: String? {
        if !located { return "Its passage changed — select the text again, or delete it. Not sent." }
        if draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Empty — not sent." }
        return nil
    }
}

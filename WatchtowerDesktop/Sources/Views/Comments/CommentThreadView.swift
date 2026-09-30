import SwiftUI
import WatchtowerCore

/// One comment thread: the quote, the comments, a status line, and the
/// actions its owner allows — a nil closure hides that control. Knows nothing
/// about where the comments live: project document/target threads (Tasks
/// 16/19) and chat artifact comments (Task 24) all pass a
/// `CommentThreadContent`.
struct CommentThreadView: View {
    let thread: CommentThreadContent
    var isActive = false
    /// Returns whether the reply was saved; the draft is cleared only then.
    var onReply: ((String) async -> Bool)?
    var onResolve: (() async -> Void)?
    var onReopen: (() async -> Void)?
    var onDelete: (() async -> Void)?
    @State private var draft = ""
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !thread.quote.isEmpty {
                Text("\u{201C}\(thread.quote)\u{201D}")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            ForEach(thread.entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.author).font(.caption).fontWeight(.semibold)
                    Text(entry.body).font(.callout).textSelection(.enabled)
                }
            }
            if let note = thread.statusNote {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            if onReply != nil {
                TextField("Reply", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
            }
            HStack {
                if let onReply {
                    Button("Reply") {
                        let text = draft
                        sending = true
                        Task {
                            let saved = await onReply(text)
                            draft = Self.draftAfterReply(sent: text, current: draft, saved: saved)
                            sending = false
                        }
                    }
                    .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Spacer()
                if let onDelete { Button("Delete", role: .destructive) { Task { await onDelete() } } }
                if let onResolve { Button("Resolve") { Task { await onResolve() } } }
                if let onReopen { Button("Reopen") { Task { await onReopen() } } }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.yellow.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
        )
    }

    /// The draft after a reply attempt: kept on a failed write (so the owner's
    /// text is never lost), cleared on success unless the owner already typed
    /// something new while the write ran.
    static func draftAfterReply(sent: String, current: String, saved: Bool) -> String {
        saved && current == sent ? "" : current
    }
}

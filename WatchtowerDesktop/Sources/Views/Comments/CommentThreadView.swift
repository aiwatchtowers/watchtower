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
    var onReply: ((String) async -> Void)?
    var onResolve: (() async -> Void)?
    var onReopen: (() async -> Void)?
    var onDelete: (() async -> Void)?
    @State private var draft = ""

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
                        draft = ""
                        Task { await onReply(text) }
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
}

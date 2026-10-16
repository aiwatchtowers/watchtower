import SwiftUI
import WatchtowerCore

/// The selected file's comments under the diff (board #328): a draft is
/// edited in place; a carried one shows the agent's reply with Resolve and
/// Edit; an outdated one quotes the lines it lost, with Resolve. A failed
/// write lands in the model's `lastError` (the pane's banner).
struct ReviewCommentListView: View {
    let model: ReviewChangesModel
    let path: String

    private var shown: [ReviewComment] {
        model.comments.filter { $0.path == path && $0.status != .resolved }
    }

    var body: some View {
        if !shown.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(shown) { comment in
                        ReviewCommentRow(model: model, comment: comment)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 220)
        }
    }
}

private struct ReviewCommentRow: View {
    let model: ReviewChangesModel
    let comment: ReviewComment
    @State private var text = ""
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(lines).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(comment.status.rawValue.capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                actions
            }
            .controlSize(.small)
            switch comment.status {
            case .draft:
                editor
            case .carried:
                if editing { editor } else { Text(comment.body).textSelection(.enabled) }
                reply
            case .outdated:
                Text(comment.quote).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(4)
                Text(comment.body).foregroundStyle(.secondary)
                reply
            case .sent, .resolved:
                Text(comment.body)
                reply
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .onAppear { text = comment.body }
        .onChange(of: comment.body) { _, body in text = body }
    }

    private var lines: String {
        let range = comment.startLine == comment.endLine ? "\(comment.startLine)" : "\(comment.startLine)–\(comment.endLine)"
        return (comment.side == "old" ? "Removed line " : "Line ") + range
    }

    @ViewBuilder private var reply: some View {
        if !comment.agentReply.isEmpty {
            Text("Agent: \(comment.agentReply)").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextEditor(text: $text)
                .font(.callout)
                .frame(minHeight: 44, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
            if text != comment.body {
                Button("Save") {
                    // A failure keeps the text and lands in lastError.
                    if (try? model.editComment(id: comment.id, body: text)) != nil { editing = false }
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch comment.status {
        case .draft:
            Button("Delete", role: .destructive) { try? model.deleteComment(id: comment.id) }
        case .carried:
            Button(editing ? "Cancel" : "Edit") {
                editing.toggle()
                text = comment.body
            }
            Button("Resolve") { try? model.resolve(id: comment.id) }
        case .outdated:
            Button("Resolve") { try? model.resolve(id: comment.id) }
        case .sent, .resolved:
            EmptyView()
        }
    }
}

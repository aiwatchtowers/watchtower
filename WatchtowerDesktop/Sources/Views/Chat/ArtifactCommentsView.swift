import SwiftUI
import WatchtowerCore

/// The artifact panel's comment mode: the latest version as selectable text
/// with every comment highlighted, the comment list, and "Send N comments".
/// It never sends by itself (CHAT-05): the send bar calls back into the chat,
/// which sends the composed text as the owner's own message.
struct ArtifactCommentsView: View {
    let comments: ArtifactCommentsModel
    let canSend: Bool
    let onSend: () -> Void
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var activeID: Int64?

    var body: some View {
        VStack(spacing: 0) {
            if let rendered = comments.rendered {
                HStack {
                    Text("Select text to comment on it.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(8)
                CommentableDocumentText(
                    text: DocumentAttributedString.make(rendered, highlights: comments.ranges, activeThreadID: activeID),
                    contentID: contentID,
                    selection: $selection,
                    onComment: { body, range in comments.add(body: body, selection: range) },
                    onClick: { activeID = comments.threadID(at: $0) ?? activeID }
                )
                .frame(minHeight: 180)
                Divider()
                list.frame(minHeight: 100, maxHeight: 260)
                Divider()
                ArtifactCommentsSendBar(count: comments.unsent.count, canSend: canSend, onSend: onSend)
            } else {
                ContentUnavailableView("Nothing to comment on yet", systemImage: "text.bubble")
            }
            if let error = comments.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(6)
            }
        }
        // A selection belongs to one artifact version; never let it anchor a
        // comment on another artifact or a newer version.
        .onChange(of: contentID) { _, _ in selection = DocumentSelectionCarry.none }
    }

    private var contentID: String {
        "\(comments.conversationID)/\(comments.key)/\(comments.artifact?.version ?? -1)"
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(comments.unsent) { row($0) }
                ForEach(comments.sent) { row($0) }
                if !comments.outdated.isEmpty {
                    DisclosureGroup("Outdated (\(comments.outdated.count))") {
                        ForEach(comments.outdated) { row($0) }
                    }
                }
                if !comments.resolved.isEmpty {
                    DisclosureGroup("Resolved (\(comments.resolved.count))") {
                        ForEach(comments.resolved) { row($0) }
                    }
                }
            }
            .padding(10)
        }
    }

    private func row(_ comment: ArtifactComment) -> some View {
        CommentThreadView(
            thread: comment.content,
            isActive: comment.id == activeID,
            onReply: nil,
            onResolve: comment.status == .sent || comment.status == .outdated ? { comments.resolve(comment.id) } : nil,
            onReopen: nil,
            onDelete: comment.status == .open ? { comments.delete(comment.id) } : nil
        )
        .onTapGesture { activeID = comment.id }
    }
}

/// "Send N comments": enabled with unsent comments and no answer streaming.
struct ArtifactCommentsSendBar: View {
    let count: Int
    let canSend: Bool
    let onSend: () -> Void

    var body: some View {
        let hasUnsent = count > 0 // swiftlint:disable:this empty_count
        HStack {
            Text(hasUnsent ? "The assistant sees them only when you send them." : "No unsent comments")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(CommentBatchComposer.sendButtonTitle(count: count), action: onSend)
                .disabled(!hasUnsent || !canSend)
                .help(canSend ? "Send the comments to the assistant as your next message"
                              : "Wait for the current answer to finish")
        }
        .padding(10)
    }
}

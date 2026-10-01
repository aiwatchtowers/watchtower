import SwiftUI
import WatchtowerCore

/// The latest artifact version as selectable text — the one view the panel
/// shows whether or not the owner is commenting, so starting a comment never
/// swaps the text out (#179) and it reads exactly as rendered (#181) — with
/// every comment highlighted, the comment list beside (or, in a narrow
/// panel, below) it while `showsList`, and "Send N comments" once there are
/// unsent ones. It never sends by itself (CHAT-05): the send bar calls back
/// into the chat, which sends the composed text as the owner's own message.
struct ArtifactCommentsView: View {
    let comments: ArtifactCommentsModel
    let rendered: RenderedDocument
    /// A draft message's header fields (To, Subject, …), shown above its text.
    var fields: [ArtifactField] = []
    let canSend: Bool
    /// The comment list is open; the owner's toggle, kept by the panel.
    @Binding var showsList: Bool
    let onSend: () -> Void
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var activeID: Int64?
    @State private var composerText = ""
    @State private var showResolved = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let beside = CommentsPanelPlacement.besideText(width: geo.size.width)
                // One layout value either way, so the text view keeps its
                // identity (and scroll position) when the panel resizes.
                let layout = beside ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    VStack(spacing: 0) {
                        if !fields.isEmpty {
                            ArtifactFieldsHeader(fields: fields).padding(12)
                            Divider()
                        }
                        text
                    }
                    if showsList, !comments.comments.isEmpty {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(width: beside ? 1 : nil, height: beside ? nil : 1)
                        list.frame(width: beside ? CommentsPanelPlacement.listWidth : nil)
                            .frame(maxHeight: beside ? .infinity : CommentsPanelPlacement.listHeight)
                    }
                }
            }
            if !comments.unsent.isEmpty {
                Divider()
                ArtifactCommentsSendBar(count: comments.unsent.count, canSend: canSend, onSend: onSend)
            }
            if let error = comments.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(6)
            }
        }
        // A selection belongs to one artifact version; never let it anchor a
        // comment on another artifact or a newer version.
        .onChange(of: contentID) { _, _ in selection = DocumentSelectionCarry.none }
    }

    private var text: some View {
        CommentableDocumentText(
            text: DocumentAttributedString.make(rendered, highlights: comments.ranges, activeThreadID: activeID),
            contentID: contentID,
            selection: $selection,
            composerText: $composerText,
            onComment: { body, range in comments.add(body: body, selection: range) },
            onClick: { location in
                // A click on a highlight opens the list on its thread.
                guard let id = comments.threadID(at: location) else { return }
                activeID = id
                showsList = true
            }
        )
        .frame(minWidth: 200, minHeight: 160)
    }

    private var contentID: String {
        "\(comments.conversationID)/\(comments.key)/\(comments.artifact?.version ?? -1)"
    }

    private var list: some View {
        ScrollViewReader { proxy in
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
                        DisclosureGroup("Resolved (\(comments.resolved.count))", isExpanded: $showResolved) {
                            ForEach(comments.resolved) { row($0) }
                        }
                    }
                }
                .padding(10)
            }
            // `initial`: a click on a highlight may open the list and pick
            // its thread in one update — the new list scrolls on appear.
            .onChange(of: activeID, initial: true) { _, id in
                guard let id else { return }
                // A resolved comment keeps its highlight; its row is folded away.
                if comments.resolved.contains(where: { $0.id == id }) { showResolved = true }
                // Two turns: the first lets a just-opened list or unfolded
                // group build its rows. No anchor: a row already in view
                // (one the owner just tapped) does not move.
                DispatchQueue.main.async {
                    DispatchQueue.main.async { withAnimation { proxy.scrollTo(id) } }
                }
            }
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
        .id(comment.id)
        .onTapGesture { activeID = comment.id }
    }
}

/// One header field of a draft message artifact.
struct ArtifactField {
    let name: String
    let value: String

    /// A draft message's header fields, empty values left out; none for
    /// other kinds.
    static func fields(of draft: ArtifactDraft) -> [Self] {
        let items: [(String, String?)] = switch draft.kind {
        case "email": [("To", draft.meta["to"]), ("Cc", draft.meta["cc"]), ("Subject", draft.meta["subject"])]
        case "slack": [("Channel", draft.meta["channel"] ?? draft.meta["permalink"])]
        case "event": [("Start", draft.meta["start"]), ("End", draft.meta["end"]),
                       ("Attendees", draft.meta["attendees"]), ("Location", draft.meta["location"])]
        default: []
        }
        return items.compactMap { name, value in
            guard let value, !value.isEmpty else { return nil }
            return Self(name: name, value: value)
        }
    }
}

/// A draft message's header fields as a two-column grid.
struct ArtifactFieldsHeader: View {
    let fields: [ArtifactField]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
            ForEach(fields, id: \.name) { field in
                GridRow {
                    Text(field.name).foregroundStyle(.secondary)
                    Text(field.value).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

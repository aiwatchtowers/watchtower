import SwiftUI
import WatchtowerCore

/// Beside an open project document: the owner's unsent drafts, then its
/// open, resolved and outdated comment threads.
struct ProjectDocumentThreadsPanel: View {
    let docVM: ProjectDocumentViewModel
    @Binding var activeThreadID: Int64?

    var body: some View {
        ScrollViewReader { proxy in
            threads
                // A click on a highlight in the text brings its thread into view.
                .onChange(of: activeThreadID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .top) } }
                }
        }
    }

    private var threads: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !docVM.drafts.isEmpty {
                    Text("Drafts — not sent yet").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                    ForEach(docVM.drafts) { draft in
                        ProjectCommentDraftRow(
                            draft: draft,
                            located: docVM.draftRanges[draft.id] != nil,
                            sending: docVM.isSending,
                            onEdit: { docVM.updateDraft(draft.id, body: $0) },
                            onDelete: { docVM.deleteDraft(draft.id) }
                        )
                    }
                    Divider()
                }
                ForEach(docVM.openThreads) { thread($0) }
                if !docVM.resolvedThreads.isEmpty {
                    DisclosureGroup("Resolved (\(docVM.resolvedThreads.count))") {
                        ForEach(docVM.resolvedThreads) { thread($0) }
                    }
                }
                if !docVM.outdatedThreads.isEmpty {
                    DisclosureGroup("Outdated (\(docVM.outdatedThreads.count))") {
                        ForEach(docVM.outdatedThreads) { thread($0) }
                    }
                }
            }
            .padding(10)
        }
    }

    private func thread(_ thread: ProjectCommentThread) -> some View {
        CommentThreadView(
            thread: thread.content,
            isActive: thread.id == activeThreadID,
            onReply: { await docVM.reply(to: thread.id, body: $0) },
            onResolve: thread.root.isOpen ? { await docVM.resolve(thread.id) } : nil,
            onReopen: thread.root.isOpen ? nil : { await docVM.reopen(thread.id) }
        )
        .id(thread.id)
        .onTapGesture { activeThreadID = thread.id }
    }
}

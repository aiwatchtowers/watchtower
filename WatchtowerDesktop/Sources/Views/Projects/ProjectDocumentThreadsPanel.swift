import SwiftUI
import WatchtowerCore

/// Beside an open project document: the owner's unsent drafts, then its
/// open, resolved and outdated comment threads.
struct ProjectDocumentThreadsPanel: View {
    let docVM: ProjectDocumentViewModel
    @Binding var activeThreadID: Int64?

    @State private var showResolved = false

    var body: some View {
        ScrollViewReader { proxy in
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
                        DisclosureGroup("Resolved (\(docVM.resolvedThreads.count))", isExpanded: $showResolved) {
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
            // A click on a highlight brings its thread into view — also when
            // that click is what opened this panel (`initial`).
            .onChange(of: activeThreadID, initial: true) { _, id in
                guard let id else { return }
                // A resolved thread keeps its highlight; its row is folded away.
                if docVM.resolvedThreads.contains(where: { $0.id == id }) { showResolved = true }
                // Two turns: the first lets a just-opened list or unfolded
                // group build its rows. No anchor: a row already in view
                // (one the owner just tapped) does not move.
                DispatchQueue.main.async {
                    DispatchQueue.main.async { withAnimation { proxy.scrollTo(id) } }
                }
            }
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

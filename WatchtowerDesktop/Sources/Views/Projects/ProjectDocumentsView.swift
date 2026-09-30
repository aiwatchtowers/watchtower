import SwiftUI
import WatchtowerCore

/// Documents pane (spec §6.3): attached documents on the left, the open one
/// in the middle as selectable text, its threads on the right.
struct ProjectDocumentsView: View {
    @Bindable var vm: ProjectsViewModel
    @Environment(AppState.self) private var appState
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var activeThreadID: Int64?
    @State private var composing = false
    @State private var draft = ""
    /// The render the open composer's `selection` was computed against —
    /// captured when the composer opens, so a reload while it's open (the
    /// file watcher fires) is detected before the stale selection is written.
    @State private var composeRenderVersion = 0
    @State private var delivery: ProjectTerminalCenter.PromptDelivery?

    var body: some View {
        HSplitView {
            list.frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            if let docVM = vm.documentViewModel {
                documentView(docVM).frame(minWidth: 360, maxWidth: .infinity)
                threads(docVM).frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            } else {
                Text(vm.documents.isEmpty
                     ? "No documents yet. Claude Code attaches specs and plans here as it writes them."
                     : "Select a document.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: vm.selectedProjectID) {
            await vm.loadDocuments()
            await vm.openPendingDocument()
        }
        .onChange(of: vm.pendingDocumentID) { _, _ in Task { await vm.openPendingDocument() } }
        .onChange(of: vm.documentViewModel?.document.id) { _, _ in
            delivery = nil
            // A selection is offsets into one document's text: never carry it
            // to another document (it would anchor text the owner never chose).
            selection = DocumentSelectionCarry.none
        }
    }

    private var list: some View {
        List(vm.documents, selection: Binding(
            get: { vm.documentViewModel?.document.id },
            set: { id in
                guard let item = vm.documents.first(where: { $0.id == id }) else { return }
                Task { await vm.openDocument(item.document) }
            }
        )) { item in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.document.displayTitle)
                    Text([item.document.kind, item.targetTitle].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if vm.isRevised(item.document) {
                    Circle().fill(Color.blue).frame(width: 6, height: 6).help("Revised since you last opened it")
                }
                if item.openComments > 0 {
                    Text("\(item.openComments)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tag(Optional(item.id))
        }
        .panelListStyle()
    }

    private func documentView(_ docVM: ProjectDocumentViewModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(docVM.document.relPath).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Comment") {
                    composeRenderVersion = docVM.renderVersion
                    composing = true
                }
                .disabled(selection.length == 0 || docVM.rendered == nil)
                .popover(isPresented: $composing) { composer(docVM) }
            }
            .padding(8)
            Divider()
            if let rendered = docVM.rendered {
                DocumentTextView(
                    text: DocumentAttributedString.make(rendered, highlights: docVM.anchoredRanges, activeThreadID: activeThreadID),
                    contentID: "\(docVM.document.id)#\(docVM.renderVersion)",
                    selection: $selection
                ) { activeThreadID = docVM.threadID(at: $0) ?? activeThreadID }
            } else {
                Text(docVM.loadError ?? "Loading…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = docVM.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(6)
            }
            Divider()
            ProjectCommentsSendBar(
                count: ProjectCommentPrompt.openOwnerCount(docVM.threads),
                delivery: delivery,
                onSend: { sendComments(docVM) },
                onOpenTerminal: openTerminal
            )
        }
    }

    private func composer(_ docVM: ProjectDocumentViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Comment on the selection").font(.headline)
            TextEditor(text: $draft).frame(width: 320, height: 100)
            HStack {
                Spacer()
                Button("Cancel") { composing = false }
                Button("Comment") {
                    let (text, range, version) = (draft, selection, composeRenderVersion)
                    Task {
                        // Only clear the draft and close on a real write: a stale
                        // `version` (the file reloaded while the popover was open)
                        // must keep the owner's typed text so they don't lose it.
                        let wrote = await docVM.addComment(body: text, selection: range, renderVersion: version)
                        if wrote {
                            draft = ""
                            composing = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    private func threads(_ docVM: ProjectDocumentViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(docVM.openThreads) { thread($0, docVM) }
                if !docVM.resolvedThreads.isEmpty {
                    DisclosureGroup("Resolved (\(docVM.resolvedThreads.count))") {
                        ForEach(docVM.resolvedThreads) { thread($0, docVM) }
                    }
                }
                if !docVM.outdatedThreads.isEmpty {
                    DisclosureGroup("Outdated (\(docVM.outdatedThreads.count))") {
                        ForEach(docVM.outdatedThreads) { thread($0, docVM) }
                    }
                }
            }
            .padding(10)
        }
    }

    private func thread(_ thread: ProjectCommentThread, _ docVM: ProjectDocumentViewModel) -> some View {
        CommentThreadView(
            thread: thread.content,
            isActive: thread.id == activeThreadID,
            onReply: { await docVM.reply(to: thread.id, body: $0) },
            onResolve: thread.root.isOpen ? { await docVM.resolve(thread.id) } : nil,
            onReopen: thread.root.isOpen ? nil : { await docVM.reopen(thread.id) }
        )
        .onTapGesture { activeThreadID = thread.id }
    }

    private func sendComments(_ docVM: ProjectDocumentViewModel) {
        let line = ProjectCommentPrompt.line(
            relPath: docVM.document.relPath, documentID: docVM.document.id,
            count: ProjectCommentPrompt.openOwnerCount(docVM.threads)
        )
        let result = appState.projectTerminalCenter.sendPrompt(line, projectID: docVM.project.id)
        delivery = result
        // The line is pasted or copied, never submitted (I1): switch to the
        // Terminal pane so the owner sees it land (or pastes it) and presses
        // Return themselves, instead of leaving it silently queued off-screen.
        if result != .noSession { vm.pane = .terminal }
    }

    private func openTerminal() {
        if let project = vm.selectedProject { appState.projectTerminalCenter.start(project: project) }
        vm.pane = .terminal
        delivery = nil
    }
}

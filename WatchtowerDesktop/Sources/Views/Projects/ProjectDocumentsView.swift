import SwiftUI
import WatchtowerCore

/// Documents pane (spec §6.3): attached documents on the left, the open one
/// in the middle as selectable text, its threads on the right.
struct ProjectDocumentsView: View {
    @Bindable var vm: ProjectsViewModel
    @Environment(AppState.self) private var appState
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var activeThreadID: Int64?
    @State private var delivery: TerminalCenter.PromptDelivery?
    @State private var showThreads = true
    @State private var addingDocument = false

    var body: some View {
        HSplitView {
            list.frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            if let docVM = vm.documentViewModel {
                documentView(docVM).frame(minWidth: 360, maxWidth: .infinity)
                // No threads or drafts, or hidden by the owner: the text takes the width.
                if showThreads, hasThreadsPanel(docVM) {
                    threads(docVM).frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
                }
            } else {
                Text(vm.documents.isEmpty
                     ? "No documents yet. Claude Code attaches specs and plans here as it writes them — or add one with Add Document…."
                     : "Select a document.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: vm.selectedProjectID) {
            await vm.loadDocuments()
            await vm.openPendingDocument()
        }
        .sheet(isPresented: $addingDocument) {
            if let project = vm.selectedProject { AddProjectDocumentSheet(vm: vm, project: project) }
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
        VStack(spacing: 0) {
            documentList
            Divider()
            HStack {
                Button {
                    addingDocument = true
                } label: {
                    Label("Add Document…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Attach a .md or .txt file from the project folder")
                Spacer()
            }
            .padding(8)
            if let notice = vm.attachNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .bottom], 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var documentList: some View {
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
                if hasThreadsPanel(docVM) {
                    Toggle(isOn: $showThreads) {
                        Label("Threads (\(docVM.threads.count + docVM.drafts.count))", systemImage: "sidebar.right")
                    }
                    .toggleStyle(.button)
                    .help(showThreads ? "Hide the comment threads" : "Show the comment threads")
                }
            }
            .padding(8)
            Divider()
            if let rendered = docVM.rendered {
                GeometryReader { geo in
                    CommentableDocumentText(
                        text: DocumentAttributedString.make(
                            rendered, highlights: docVM.anchoredRanges, activeThreadID: activeThreadID,
                            drafts: Array(docVM.draftRanges.values)
                        ),
                        contentID: "\(docVM.document.id)#\(docVM.renderVersion)",
                        selection: $selection,
                        horizontalInset: ReadableColumn.horizontalInset(forWidth: geo.size.width),
                        onComment: { body, range in
                            guard docVM.addDraft(body: body, selection: range) else { return false }
                            showThreads = true
                            return true
                        },
                        onClick: { location in
                            guard let id = docVM.threadID(at: location) else { return }
                            activeThreadID = id
                            showThreads = true
                        }
                    )
                }
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
                count: ProjectCommentPrompt.openOwnerCount(docVM.threads) + docVM.sendableDraftCount,
                drafts: docVM.sendableDraftCount,
                delivery: delivery,
                onSend: { Task { await sendComments(docVM) } },
                onOpenTerminal: openTerminal
            )
        }
    }

    private func hasThreadsPanel(_ docVM: ProjectDocumentViewModel) -> Bool {
        !docVM.threads.isEmpty || !docVM.drafts.isEmpty
    }

    private func threads(_ docVM: ProjectDocumentViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !docVM.drafts.isEmpty {
                    Text("Drafts — not sent yet").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                    ForEach(docVM.drafts) { draft in
                        ProjectCommentDraftRow(
                            draft: draft,
                            located: docVM.draftRanges[draft.id] != nil,
                            onEdit: { docVM.updateDraft(draft.id, body: $0) },
                            onDelete: { docVM.deleteDraft(draft.id) }
                        )
                    }
                    Divider()
                }
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

    /// Saves the drafts first (all or none); a failed save types nothing and
    /// leaves the drafts and the reason on screen.
    private func sendComments(_ docVM: ProjectDocumentViewModel) async {
        guard await docVM.sendDrafts() else { return }
        let line = ProjectCommentPrompt.line(
            relPath: docVM.document.relPath, documentID: docVM.document.id,
            count: ProjectCommentPrompt.openOwnerCount(docVM.threads)
        )
        let center = appState.terminalCenter
        let target = center.activeSession(projectID: docVM.project.id)
        let result = target.map { center.sendPrompt(line, sessionID: $0.id) } ?? .noSession
        delivery = result
        // The line is pasted or copied, never submitted (I1): put that
        // session on screen — beside the document in a split, where nothing
        // moves if it is already shown — so the owner sees it land (or
        // pastes it) and presses Return themselves.
        if result != .noSession, let target { vm.showTerminal(sessionID: target.id, projectID: docVM.project.id) }
    }

    private func openTerminal() {
        if let project = vm.selectedProject {
            Task { await vm.openMostRecentSession(project: project, placement: .keeping(.documents)) }
        }
        delivery = nil
    }
}

/// One unsent draft in the threads panel: its passage, its editable text and
/// Delete. A draft whose passage left the document is kept but not sent.
private struct ProjectCommentDraftRow: View {
    let draft: ProjectCommentDraft
    let located: Bool
    let onEdit: (String) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\u{201C}\(draft.anchor.quote)\u{201D}")
                .font(.caption)
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(3)
            TextField("Comment", text: Binding(get: { draft.body }, set: onEdit), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
            HStack {
                if !located {
                    Text("Its passage changed — select the text again, or delete it.")
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
    }
}

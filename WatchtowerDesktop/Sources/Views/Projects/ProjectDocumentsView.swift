import SwiftUI
import WatchtowerCore

/// Documents pane (spec §6.3): attached documents on the left, the open one
/// in the middle as selectable text, its threads on the right.
struct ProjectDocumentsView: View {
    @Bindable var vm: ProjectsViewModel
    @Environment(AppState.self) private var appState
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var activeThreadID: Int64?
    /// The selection composer's typed text, kept here so a document that
    /// briefly fails to read (the text view goes away) does not drop it.
    @State private var composerText = ""
    @State private var delivery: TerminalCenter.PromptDelivery?
    @State private var showThreads = true
    @State private var addingDocument = false
    /// The last table-of-contents jump in the open document.
    @State private var scrollTarget: DocumentScrollTarget?

    var body: some View {
        HSplitView {
            ProjectDocumentsList(vm: vm) { addingDocument = true }
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            if let docVM = vm.documentViewModel {
                documentView(docVM).frame(minWidth: 360, maxWidth: .infinity)
                // No threads or drafts, or hidden by the owner: the text takes the width.
                if showThreads, hasThreadsPanel(docVM) {
                    ProjectDocumentThreadsPanel(docVM: docVM, activeThreadID: $activeThreadID).frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
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
        // New drafts after a send: the old "pasted" note no longer covers them.
        .onChange(of: vm.documentViewModel?.sendableDraftCount) { _, count in
            if (count ?? 0) > 0 { delivery = nil }
        }
        .onChange(of: vm.documentViewModel?.document.id) { _, _ in
            delivery = nil
            // A selection is offsets into one document's text: never carry it
            // to another document (it would anchor text the owner never chose).
            selection = DocumentSelectionCarry.none
            // Nor the half-typed composer text written for the other document.
            composerText = ""
            scrollTarget = nil
        }
    }

    private func documentView(_ docVM: ProjectDocumentViewModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(docVM.document.relPath).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let rendered = docVM.rendered {
                    DocumentContentsMenu(headings: rendered.headings) { scrollTarget = DocumentScrollTarget(offset: $0) }
                }
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
                        composerText: $composerText,
                        horizontalInset: ReadableColumn.horizontalInset(forWidth: geo.size.width),
                        scrollTarget: scrollTarget,
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
                unsendableDrafts: docVM.unsendableDraftCount,
                sending: docVM.isSending,
                delivery: delivery,
                onSend: { Task { await sendComments(docVM) } },
                onOpenTerminal: openTerminal
            )
        }
    }

    private func hasThreadsPanel(_ docVM: ProjectDocumentViewModel) -> Bool {
        !docVM.threads.isEmpty || !docVM.drafts.isEmpty
    }

    /// Saves the drafts first (all or none); a failed save types nothing and
    /// leaves the drafts and the reason on screen.
    private func sendComments(_ docVM: ProjectDocumentViewModel) async {
        delivery = nil
        let before = ProjectCommentPrompt.openOwnerCount(docVM.threads)
        guard let written = await docVM.sendDrafts() else { return }
        // A failed reload after the commit leaves `threads` stale: never count fewer than were open plus sent.
        let count = max(ProjectCommentPrompt.openOwnerCount(docVM.threads), before + written)
        let line = ProjectCommentPrompt.line(
            relPath: docVM.document.relPath, documentID: docVM.document.id, count: count
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

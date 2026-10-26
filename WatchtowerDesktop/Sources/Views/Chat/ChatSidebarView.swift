import SwiftUI
import WatchtowerCore

/// History on the left (spec 2026-10-26 §6): Pinned / Recent / the folded
/// "▸ N older", with rename, pin, archive, delete. The header switches
/// between All chats and one project (§4); a project's first row is its
/// Project overview.
/// Shaped like the Workbench sessions panel: section labels in the app
/// sidebar's style, rows as tabs, and the chat (or project page) on screen
/// is a tab that runs on into the conversation beside it (`panelTab`, with
/// `ChatSplitView` putting the panel on `panelSurface()`).
struct ChatSidebarView: View {
    @Bindable var historyVM: ChatHistoryViewModel
    let chatVM: ChatViewModel
    let onNewChat: () -> Void
    let onArchive: (Int64) -> Void
    let onDelete: (Int64) -> Void
    /// ✕ / ⌘⌫ on a chat that neither answers nor waits: deleted at once with
    /// Undo (`ChatHistoryViewModel.deleteWithUndo`); the split view lands
    /// when it was the chat on screen.
    var onQuickDelete: (Int64) -> Void = { _ in }
    @State private var renaming: ChatConversation?
    @State private var renameText = ""
    @State private var deleting: ChatConversation?
    /// The panel holds the keyboard (`SessionsPanelKeyView`, spec §5.4).
    @State private var hasKeyboard = false
    /// The row under the mouse: its ✕ shows.
    @State private var hoveredRow: Int64?
    /// The history follows the selected chat (board #561), view-local.
    @State private var scroll = PanelSelectionScrollPolicy<Int64>()

    var body: some View {
        let conversationIDs = historyVM.visibleRowIDs
        VStack(spacing: 0) {
            ChatPanelHeader(historyVM: historyVM, projectName: levelProjectName, actions: headerActions)
            // No List selection: its highlight would draw over the tab. The
            // tab follows `historyVM.selectedConversationID`, a row opens on
            // its own click (VoiceOver has the row's action) and sends the
            // keyboard to the composer.
            // Labels are rows, not Section headers: a header draws the plain
            // list's band. The list follows the selected chat, which may be
            // selected before it is listed (the policy keeps it pending).
            ScrollViewReader { proxy in
                List {
                    if let projectID = historyVM.level.projectID { projectOverviewRow(projectID) }
                    ForEach(historyVM.sections) { section in
                        if section.kind == .older {
                            olderHeader(count: section.items.count)
                            // Folded: only the chat on screen, pinned under the header.
                            ForEach(historyVM.olderExpanded ? section.items : historyVM.pinnedOlderRow.map { [$0] } ?? []) {
                                chatRow($0)
                            }
                        } else {
                            sectionLabel(Text(section.kind.title.uppercased()))
                            ForEach(section.items) { chatRow($0) }
                        }
                    }
                }
                // Sits in a plain HStack (ChatView's ChatSplitView), not a
                // NavigationSplitView column — see panelListStyle. The panel's
                // colour and edge line are `panelSurface()`'s, behind the tabs.
                .clearPlainList()
                // ↑ ↓ Return ⌘⌫ ⌘Z once a click on the list's empty space, a
                // label, the older header, a ✕ or Undo gave the panel the
                // keyboard (the sessions panel's key view, spec §5.4).
                .background(SessionsPanelKeyView(
                    keyboardRequest: historyVM.panelKeyboardSerial,
                    onCommand: performPanelKey
                ) { has in
                    hasKeyboard = has
                    if has { historyVM.enterPanelKeyboard() }
                })
                .onChange(of: historyVM.panelCursor) { _, id in
                    if hasKeyboard { proxy.followSelection(id) }
                }
                .onChange(of: historyVM.selectedConversationID, initial: true) { _, id in
                    proxy.followSelection(scroll.panelScrollTarget(selecting: id, rows: conversationIDs))
                }
                // The Project overview row is keyed by a string, never a chat id.
                .onChange(of: conversationIDs) { _, ids in
                    proxy.followSelection(scroll.panelScrollTarget(rows: ids))
                }
            }
            // The delete's Undo in its own bar under the list: it covers no
            // row, and only its Undo hands the panel the keyboard.
            ChatDeleteToast(historyVM: historyVM)
            if let error = historyVM.lastError {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        // The tab left (or the panel hidden): the waiting delete commits.
        .onDisappear { Task { await historyVM.commitPendingDelete() } }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let conv = renaming {
                    let title = renameText
                    Task { await historyVM.rename(conv.id, title: title) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete Chat?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let conv = deleting { onDelete(conv.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This conversation will be permanently deleted.")
        }
    }

    /// The level's project name; nil at All chats. A project not (yet) in
    /// `chatVM.projects` — just created, reloading — still reads as one.
    private var levelProjectName: String? {
        guard let id = historyVM.level.projectID else { return nil }
        return chatVM.projects.first { $0.id == id }?.name ?? "Project"
    }

    private var headerActions: ChatPanelHeaderActions {
        ChatPanelHeaderActions(
            newChat: onNewChat,
            selectProject: selectProject,
            newProject: {
                historyVM.selectedConversationID = nil
                Task {
                    if let id = await chatVM.createProject(name: "") { historyVM.selectLevel(.project(id)) }
                }
            },
            showAll: { historyVM.selectLevel(.all) }
        )
    }

    /// A project's first row (spec §4): its page, the tab while it is on
    /// screen. Keyed apart from the chats, whose ids also count from 1.
    private func projectOverviewRow(_ projectID: Int64) -> some View {
        Label("Project overview", systemImage: "folder")
            .lineLimit(1)
            .panelTab(isSelected: chatVM.openProjectID == projectID)
            .onTapGesture { open(projectID) }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open(projectID) }
            .id("project-overview-\(projectID)")
    }

    /// A chat's row: its state dot, title and second line (spec §5.1);
    /// "Answering" is read live from the pool at render time. In All chats
    /// a project chat's second line names its project.
    /// The ✕ shows while the row is hovered or under the panel cursor, and
    /// only when the chat neither answers nor waits (spec §5.3).
    private func chatRow(_ row: ChatPanelRow) -> some View {
        let conv = row.conversation
        let state = historyVM.state(of: row)
        let hasCursor = hasKeyboard && historyVM.panelCursor == conv.id
        return ChatPanelRowView(
            row: row,
            state: state,
            secondLine: state.secondLine(for: row, now: historyVM.now(), showsProject: historyVM.level == .all)
        ) {
            if state.allowsQuickDelete, hasCursor || hoveredRow == conv.id {
                ChatRowDeleteButton {
                    historyVM.requestPanelKeyboard()
                    quickDelete(conv)
                }
            }
        }
            .overlay {
                if hasCursor {
                    RoundedRectangle(cornerRadius: Radius.control)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .panelTab(isSelected: historyVM.selectedConversationID == conv.id)
            .onTapGesture { select(conv.id) }
            .onHover { inside in
                if inside {
                    hoveredRow = conv.id
                } else if hoveredRow == conv.id {
                    hoveredRow = nil
                }
            }
            .accessibilityAddTraits(hasCursor ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select(conv.id) }
            .accessibilityAction(named: "Delete") { quickDelete(conv) }
            .contextMenu { menu(conv) }
    }

    /// At once with Undo, or — while it answers or waits — the alert.
    private func quickDelete(_ conv: ChatConversation) {
        if historyVM.deleteWithUndo(conv.id) {
            onQuickDelete(conv.id)
        } else {
            deleting = conv
        }
    }

    /// What each panel key does (spec §5.4); true when it was taken. Esc
    /// lets the keyboard go; ⌘Z with nothing to undo passes on.
    private func performPanelKey(_ command: SessionsPanelKeyView.Command) -> Bool {
        switch command {
        case .cursorUp:
            historyVM.movePanelCursor(-1)
        case .cursorDown:
            historyVM.movePanelCursor(1)
        case .openCursor:
            if let id = historyVM.listedPanelCursor { historyVM.selectedConversationID = id }
        case .handBack:
            return false
        case .deleteCursor:
            if let id = historyVM.listedPanelCursor, let conv = historyVM.rows.first(where: { $0.id == id })?.conversation {
                quickDelete(conv)
            }
        case .undoDelete:
            return historyVM.undoPendingDelete() != nil
        }
        return true
    }

    /// The older group's header, "▸ N older" (spec §6), the sessions
    /// panel's "▸ N finished": a click opens or folds it, remembered per level.
    private func olderHeader(count: Int) -> some View {
        PanelFoldHeader(count: count, label: "older", itemName: "chat", expanded: historyVM.olderExpanded) {
            historyVM.olderExpanded.toggle()
            historyVM.requestPanelKeyboard()
        }
        .padding(.top, Spacing.regular)
    }

    /// A section's label row (PINNED, RECENT…) in the app sidebar's
    /// style, aligned with the tabs' text.
    private func sectionLabel(_ title: Text) -> some View {
        HStack(spacing: Spacing.small) {
            title
                .sidebarSectionLabel()
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Spacing.small)
        }
        .contentShape(Rectangle())
        .onTapGesture { historyVM.requestPanelKeyboard() }
        .frame(minHeight: 18)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// A row click: the chat opens and the composer takes the keyboard.
    private func select(_ conversationID: Int64) {
        historyVM.selectedConversationID = conversationID
        chatVM.requestComposerFocus()
    }

    /// A project picked in the switcher: its level. The chat on screen stays
    /// when the project lists it; otherwise (another project's chat, the
    /// landing, another page) the project's overview opens, so the detail
    /// is always a listed tab.
    private func selectProject(_ projectID: Int64) {
        historyVM.selectLevel(.project(projectID))
        let shown = historyVM.selectedConversationID
        if shown == nil || !historyVM.rows.contains(where: { $0.id == shown }) { open(projectID) }
    }

    private func open(_ projectID: Int64) {
        historyVM.selectedConversationID = nil
        chatVM.openProject(projectID)
    }

    @ViewBuilder
    private func menu(_ conv: ChatConversation) -> some View {
        Button("Rename…") {
            renameText = conv.title
            renaming = conv
        }
        Button(conv.pinned ? "Unpin" : "Pin") { Task { await historyVM.togglePin(conv.id) } }
            .disabled(historyVM.pendingWrites.isPending("pin:\(conv.id)"))
        if !chatVM.projects.isEmpty || conv.projectID != nil {
            Menu("Move to Project") {
                Button("None") { Task { await chatVM.moveConversation(conv.id, toProject: nil) } }
                    .disabled(conv.projectID == nil)
                ForEach(chatVM.projects) { project in
                    Button(project.name) { Task { await chatVM.moveConversation(conv.id, toProject: project.id) } }
                        .disabled(conv.projectID == project.id)
                }
            }
        }
        Button("Archive") { onArchive(conv.id) }
        Divider()
        Button("Delete…", role: .destructive) { deleting = conv }
    }
}

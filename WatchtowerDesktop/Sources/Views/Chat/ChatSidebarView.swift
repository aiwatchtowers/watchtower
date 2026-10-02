import SwiftUI
import WatchtowerCore

/// History on the left (spec §3.1): Pinned / Today / Yesterday / 7 / 30 /
/// Older, with rename, pin, archive, delete. Projects (Phase 4) sit above.
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
    @State private var renaming: ChatConversation?
    @State private var renameText = ""
    @State private var deleting: ChatConversation?
    /// The history takes ↑/↓ once a row was clicked, as the List's own
    /// selection did.
    @FocusState private var historyFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats").font(.headline)
                Spacer()
                Button(action: onNewChat) { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .help("New Chat (⌘N)")
                    .accessibilityLabel("New Chat (⌘N)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // No List selection: its highlight would draw over the tab. The
            // tab follows `historyVM.selectedConversationID`, a row selects
            // on its own click (VoiceOver has the row's action) and ↑/↓ move
            // the selection while the history has focus.
            // Labels are rows, not Section headers: a header draws the plain
            // list's band.
            List {
                projectsSection
                ForEach(historyVM.sections) { section in
                    sectionLabel(Text(section.kind.title.uppercased()))
                    ForEach(section.conversations) { conv in
                        Text(conv.displayTitle)
                            .lineLimit(1)
                            .panelTab(isSelected: historyVM.selectedConversationID == conv.id)
                            .onTapGesture { select(conv.id) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { select(conv.id) }
                            .contextMenu { menu(conv) }
                    }
                }
            }
            // Sits in a plain HStack (ChatView's ChatSplitView), not a
            // NavigationSplitView column — see panelListStyle. The panel's
            // colour and edge line are `panelSurface()`'s, behind the tabs.
            .clearPlainList()
            .focusable()
            .focused($historyFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { historyVM.selectAdjacent(by: -1) ? .handled : .ignored }
            .onKeyPress(.downArrow) { historyVM.selectAdjacent(by: 1) ? .handled : .ignored }
            if let error = historyVM.lastError {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let conv = renaming { historyVM.rename(conv.id, title: renameText) }
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

    /// Projects above the history (spec §6.1). Opening one clears the
    /// history selection, so picking the previously shown chat afterwards
    /// is still a selection change that leaves the project page.
    @ViewBuilder
    private var projectsSection: some View {
        sectionLabel(Text("PROJECTS")) {
            Button {
                historyVM.selectedConversationID = nil
                chatVM.createProject(name: "")
            } label: {
                Image(systemName: "plus").imageScale(.small)
            }
            .buttonStyle(.borderless)
            .help("New Project")
            .accessibilityLabel("New Project")
        }
        // Keyed apart from the chats: the list's rows share one identity
        // space, and project and chat ids both count from 1.
        ForEach(chatVM.projects, id: \.sidebarRowKey) { project in
            Label(project.name, systemImage: "folder")
                .lineLimit(1)
                .panelTab(isSelected: chatVM.openProjectID == project.id)
                .onTapGesture { open(project.id) }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { open(project.id) }
        }
    }

    /// A section's label row (PROJECTS, PINNED, TODAY…) in the app sidebar's
    /// style, aligned with the tabs' text, with an optional trailing control.
    private func sectionLabel(
        _ title: Text, @ViewBuilder trailing: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(spacing: 4) {
            title
                .sidebarSectionLabel()
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            trailing()
        }
        .frame(minHeight: 18)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func select(_ conversationID: Int64) {
        historyFocused = true
        historyVM.selectedConversationID = conversationID
    }

    private func open(_ projectID: Int64) {
        historyFocused = true
        historyVM.selectedConversationID = nil
        chatVM.openProject(projectID)
    }

    @ViewBuilder
    private func menu(_ conv: ChatConversation) -> some View {
        Button("Rename…") {
            renameText = conv.title
            renaming = conv
        }
        Button(conv.pinned ? "Unpin" : "Pin") { historyVM.togglePin(conv.id) }
        if !chatVM.projects.isEmpty || conv.projectID != nil {
            Menu("Move to Project") {
                Button("None") { chatVM.moveConversation(conv.id, toProject: nil) }
                    .disabled(conv.projectID == nil)
                ForEach(chatVM.projects) { project in
                    Button(project.name) { chatVM.moveConversation(conv.id, toProject: project.id) }
                        .disabled(conv.projectID == project.id)
                }
            }
        }
        Button("Archive") { onArchive(conv.id) }
        Divider()
        Button("Delete…", role: .destructive) { deleting = conv }
    }
}

private extension ChatProject {
    /// The history list's row identity for a project row, distinct from any
    /// chat's id (`ChatSidebarView.projectsSection`).
    var sidebarRowKey: String { "project-\(id)" }
}

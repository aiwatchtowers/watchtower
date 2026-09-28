import SwiftUI
import WatchtowerCore

/// History on the left (spec §3.1): Pinned / Today / Yesterday / 7 / 30 /
/// Older, with rename, pin, archive, delete. Projects (Phase 4) sit above.
struct ChatSidebarView: View {
    @Bindable var historyVM: ChatHistoryViewModel
    let chatVM: ChatViewModel
    let onNewChat: () -> Void
    let onDelete: (Int64) -> Void
    @State private var renaming: ChatConversation?
    @State private var renameText = ""
    @State private var deleting: ChatConversation?

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
            List(selection: $historyVM.selectedConversationID) {
                projectsSection
                ForEach(historyVM.sections) { section in
                    Section(section.kind.title) {
                        ForEach(section.conversations) { conv in
                            Text(conv.displayTitle)
                                .lineLimit(1)
                                .tag(conv.id)
                                .contextMenu { menu(conv) }
                        }
                    }
                }
            }
            // `.sidebar` requests the system source-list vibrancy material —
            // correct only as the leading column of a real NavigationSplitView.
            // This List sits in a plain HStack (ChatView's ChatSplitView), so
            // the material renders without its split-view backing and samples
            // the desktop wallpaper instead, tinting both the row background
            // and the selection highlight (owner report: solid brown panel).
            // `.plain` + an explicit background matches the app's own
            // hand-rolled SidebarView, which never requests that material.
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
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
    private var projectsSection: some View {
        Section {
            ForEach(chatVM.projects) { project in
                Button { open(project.id) } label: {
                    Label(project.name, systemImage: "folder")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(chatVM.openProjectID == project.id ? Color.accentColor.opacity(0.15) : nil)
            }
        } header: {
            HStack {
                Text("Projects")
                Spacer()
                Button {
                    historyVM.selectedConversationID = nil
                    chatVM.createProject(name: "")
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New Project")
                    .accessibilityLabel("New Project")
            }
        }
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
        Button("Archive") {
            chatVM.forget(conversationID: conv.id)
            historyVM.archive(conv.id)
        }
        Divider()
        Button("Delete…", role: .destructive) { deleting = conv }
    }
}

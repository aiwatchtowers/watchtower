import SwiftUI
import WatchtowerCore

struct ChatView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if let chatVM = appState.chatViewModel, let historyVM = appState.chatHistoryViewModel {
                ChatSplitView(chatVM: chatVM, historyVM: historyVM)
            } else {
                ProgressView()
            }
        }
        .onAppear { appState.ensureChatViewModels() }
        .task { await appState.aiModelCatalog.load() }
    }
}

/// Holds view-local layout state; the VMs live on AppState and survive tab switches.
private struct ChatSplitView: View {
    @Environment(AppState.self) private var appState
    @Bindable var chatVM: ChatViewModel
    @Bindable var historyVM: ChatHistoryViewModel
    @State private var showSidebar = true
    @State private var showSearch = false
    @State private var showRename = false
    @State private var renameText = ""

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if showSidebar {
                    ChatSidebarView(historyVM: historyVM, chatVM: chatVM, onNewChat: createNewChat, onDelete: delete)
                        .frame(width: 260)
                    Divider()
                }
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    if let projectID = chatVM.openProjectID, let dbPool = appState.databaseManager?.dbPool {
                        ProjectDetailView(
                            projectID: projectID,
                            dbPool: dbPool,
                            attachmentsRoot: ChatAttachmentStore.defaultRootDir(),
                            onNewChat: createNewChat(inProject:),
                            onOpenChat: { historyVM.selectedConversationID = $0 },
                            onRenamed: { chatVM.reloadProjects() },
                            onDeleted: { chatVM.projectDeleted($0) }
                        )
                        .id(projectID)
                    } else {
                        ChatThreadView(chatVM: chatVM, ownerName: appState.owner.displayName)
                        ChatComposerView(
                            chatVM: chatVM,
                            modelSuggestions: appState.aiModelCatalog.suggestions(for: chatVM.selectedProvider.rawValue),
                            maxHeight: max(120, geo.size.height * 0.4)
                        )
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .onChange(of: historyVM.selectedConversationID) { _, newID in
            if let newID { chatVM.select(conversationID: newID) }
        }
        .sheet(isPresented: $showSearch) {
            ChatSearchView(search: { historyVM.search($0) }, onOpen: open)
        }
        .alert("Rename Chat", isPresented: $showRename) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let id = chatVM.conversationID {
                    historyVM.rename(id, title: renameText)
                    chatVM.reload()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .inspector(isPresented: Binding(
            get: { chatVM.artifactPanel != nil },
            set: { if !$0 { chatVM.closeArtifactPanel() } }
        )) {
            if let panel = chatVM.artifactPanel {
                ArtifactPanelView(model: panel, gmailConnected: chatVM.gmailConnected, slackLinks: chatVM.slackLinks) {
                    chatVM.closeArtifactPanel()
                }
                .inspectorColumnWidth(min: 320, ideal: 460, max: 900)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() } } label: {
                Image(systemName: "sidebar.leading")
            }
            .help("Toggle Chat History")
            .accessibilityLabel("Toggle Chat History")
            Text(toolbarTitle)
                .font(.headline)
                .lineLimit(1)
                .onTapGesture(count: 2) {
                    guard chatVM.openProjectID == nil, chatVM.conversationID != nil else { return }
                    renameText = chatVM.currentConversation?.title ?? ""
                    showRename = true
                }
                .help("Double-click to rename")
            Spacer()
            Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                .keyboardShortcut("k", modifiers: .command)
                .help("Search Chats (⌘K)")
                .accessibilityLabel("Search Chats (⌘K)")
            Button(action: createNewChat) { Image(systemName: "square.and.pencil") }
                .keyboardShortcut("n", modifiers: .command)
                .help("New Chat (⌘N)")
                .accessibilityLabel("New Chat (⌘N)")
            Button { appState.startOnboarding() } label: { Image(systemName: "person.crop.circle.badge.questionmark") }
                .help(appState.profileComplete ? "Update Profile" : "Setup Profile")
                .accessibilityLabel(appState.profileComplete ? "Update Profile" : "Setup Profile")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var toolbarTitle: String {
        if let projectID = chatVM.openProjectID {
            return chatVM.projects.first { $0.id == projectID }?.name ?? "Project"
        }
        return chatVM.currentConversation?.displayTitle ?? "New Chat"
    }

    private func createNewChat() {
        if let id = chatVM.newConversation() { historyVM.selectedConversationID = id }
    }

    private func createNewChat(inProject projectID: Int64) {
        if let id = chatVM.newConversation(projectID: projectID) { historyVM.selectedConversationID = id }
    }

    private func delete(_ id: Int64) {
        chatVM.forget(conversationID: id)
        historyVM.deleteConversation(id)
        if let next = historyVM.selectedConversationID { chatVM.select(conversationID: next) }
    }

    private func open(_ hit: ChatSearchHit) {
        chatVM.open(hit)
        historyVM.selectedConversationID = hit.conversationID
    }
}

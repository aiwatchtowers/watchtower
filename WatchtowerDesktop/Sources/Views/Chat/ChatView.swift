import AppKit
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
/// Two columns by default (app sidebar + conversation/landing): the chat
/// history is opt-in, and the owner's show/hide choice is remembered.
struct ChatSplitView: View {
    static let historyWidth: CGFloat = 260

    @Environment(AppState.self) private var appState
    @Bindable var chatVM: ChatViewModel
    @Bindable var historyVM: ChatHistoryViewModel
    @AppStorage("chat.historyVisible") private var showSidebar = false
    /// The conversation last on screen (0 = the landing), when it last was,
    /// and in which workspace database — `ChatLandingPolicy`'s inputs after a
    /// relaunch; ignored when the workspace differs.
    @AppStorage("chat.lastConversationID") private var lastConversationID = 0
    @AppStorage("chat.lastViewedAt") private var lastViewedAt = 0.0
    @AppStorage("chat.lastWorkspace") private var lastWorkspace = ""
    @Environment(\.scenePhase) private var scenePhase
    /// Coarse "still on screen" stamp while the tab is shown.
    private let viewedTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @State private var showSearch = false
    @State private var showRename = false
    @State private var renameText = ""

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if showSidebar {
                    ChatSidebarView(
                        historyVM: historyVM, chatVM: chatVM,
                        onNewChat: createNewChat, onArchive: archive, onDelete: delete
                    )
                        .frame(width: Self.historyWidth)
                        // Its edge line lies under the tabs, so the chat on
                        // screen runs on into the conversation (`panelTab`).
                        .panelSurface()
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
                            onDeleted: { chatVM.projectDeleted($0) },
                            onPromptChanged: { chatVM.projectPromptChanged($0) }
                        )
                        .id(projectID)
                    } else if chatVM.isOnLanding {
                        ChatLandingView(
                            chatVM: chatVM,
                            recents: ChatLandingPolicy.recents(historyVM.conversations),
                            ownerName: appState.owner.displayName,
                            modelSuggestions: appState.aiModelCatalog.suggestions(for: chatVM.selectedProvider.rawValue),
                            maxComposerHeight: max(120, geo.size.height * 0.4)
                        ) { historyVM.selectedConversationID = $0 }
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
            // The conversation on the detail backdrop (as `MainNavigationView`
            // also paints it), so the selected history tab meets one colour.
            .detailBackground()
        }
        .onChange(of: historyVM.selectedConversationID) { _, newID in
            if let newID { chatVM.select(conversationID: newID) }
        }
        .onAppear(perform: enterTab)
        // "On screen" stamps: leaving the tab, switching chats, the app
        // going to the background or quitting, and every minute in between.
        .onDisappear(perform: rememberShownConversation)
        .onChange(of: chatVM.conversationID) { _, _ in rememberShownConversation() }
        .onChange(of: chatVM.isOnLanding) { _, _ in rememberShownConversation() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { rememberShownConversation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            rememberShownConversation()
        }
        .onReceive(viewedTicker) { _ in
            if scenePhase == .active { rememberShownConversation() }
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
            get: { chatVM.inspectorMode != nil },
            set: { if !$0 { chatVM.closeInspector() } }
        )) {
            ChatInspectorContent(chatVM: chatVM)
                .inspectorColumnWidth(min: 320, ideal: 460, max: 900)
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
                    guard chatVM.openProjectID == nil, !chatVM.isOnLanding, chatVM.conversationID != nil else { return }
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
            Button {
                Task { await appState.rerunOnboarding() }
            } label: { Image(systemName: "person.crop.circle.badge.questionmark") }
                .disabled(appState.needsOnboarding || appState.isPreparingRerun)
                .alert(
                    "Could not run setup again",
                    isPresented: Binding(
                        get: { appState.rerunError != nil },
                        set: { if !$0 { appState.clearRerunError() } }
                    )
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(appState.rerunError ?? "")
                }
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
        if chatVM.isOnLanding { return "New Chat" }
        return chatVM.currentConversation?.displayTitle ?? "New Chat"
    }

    /// ⌘N / New Chat: the landing — its composer makes the conversation on
    /// the first keystroke, so no empty row is written up front.
    private func createNewChat() {
        showLanding()
    }

    private func showLanding() {
        chatVM.showLanding()
        historyVM.selectedConversationID = nil
    }

    private var workspaceKey: String { appState.databaseManager?.dbPool.path ?? "" }

    private func enterTab() {
        let sameWorkspace = lastWorkspace == workspaceKey
        let remembered = !sameWorkspace || lastConversationID == 0 ? nil : Int64(lastConversationID)
        let viewedAt = !sameWorkspace || lastViewedAt == 0 ? nil : Date(timeIntervalSince1970: lastViewedAt)
        chatVM.enterTab(rememberedConversationID: remembered, lastViewedAt: viewedAt, now: Date())
        // A project page stays open, with no history selection.
        guard chatVM.openProjectID == nil else { return }
        historyVM.selectedConversationID = chatVM.isOnLanding ? nil : chatVM.conversationID
    }

    private func rememberShownConversation() {
        guard chatVM.openProjectID == nil else { return }
        lastConversationID = chatVM.isOnLanding ? 0 : Int(chatVM.conversationID ?? 0)
        lastViewedAt = Date().timeIntervalSince1970
        lastWorkspace = workspaceKey
    }

    private func createNewChat(inProject projectID: Int64) {
        if let id = chatVM.newConversation(projectID: projectID) { historyVM.selectedConversationID = id }
    }

    private func delete(_ id: Int64) {
        let wasShown = id == chatVM.conversationID
        chatVM.forget(conversationID: id)
        historyVM.deleteConversation(id)
        if wasShown { showLanding() }
    }

    /// Archiving the chat on screen lands, like deleting it.
    private func archive(_ id: Int64) {
        let wasShown = id == chatVM.conversationID
        chatVM.forget(conversationID: id)
        historyVM.archive(id)
        if wasShown { showLanding() }
    }

    private func open(_ hit: ChatSearchHit) {
        chatVM.open(hit)
        historyVM.selectedConversationID = hit.conversationID
    }
}

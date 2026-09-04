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

/// Extracted so that @State (historyWidth, showHistory) lives here — survives tab switches
/// because AppState keeps the VMs alive and this view just re-renders around them.
private struct ChatSplitView: View {
    @Environment(AppState.self) private var appState
    @Bindable var chatVM: ChatViewModel
    let historyVM: ChatHistoryViewModel
    @State private var showHistory = true
    @State private var historyWidth: CGFloat = 240
    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                chatToolbar
                Divider()
                chatContent
            }
            .frame(maxWidth: .infinity)

            if showHistory {
                ResizeHandle { delta in
                    historyWidth = min(max(historyWidth - delta, 160), 400)
                }

                Divider()

                ChatHistoryView(historyVM: historyVM) {
                    createNewChat()
                }
                .frame(width: historyWidth)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onChange(of: historyVM.selectedConversationID) { _, newID in
            if let newID, let conv = historyVM.conversations.first(where: { $0.id == newID }) {
                chatVM.bind(to: conv)
            }
        }
        // L6: confirmation dialog before deleting chat
        .alert("Delete Chat?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { deleteCurrentChat() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This conversation will be permanently deleted.")
        }
    }

    private func createNewChat() {
        guard let conv = historyVM.createConversation() else { return }
        chatVM.newChat()
        chatVM.bind(to: conv)
    }

    private func deleteCurrentChat() {
        guard let id = chatVM.conversationID else { return }
        chatVM.cancelStream()
        historyVM.deleteConversation(id)
        chatVM.newChat()
        // Switch to the next available conversation, or leave empty
        if let next = historyVM.conversations.first {
            chatVM.bind(to: next)
        }
    }

    private var chatToolbar: some View {
        HStack(spacing: 8) {
            Picker("Provider", selection: Binding(
                get: { chatVM.selectedProvider },
                set: { chatVM.switchProvider($0) }
            )) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 100)
            .disabled(chatVM.isStreaming)

            Picker("Model", selection: $chatVM.selectedModel) {
                Text("Auto").tag("")
                ForEach(appState.aiModelCatalog.suggestions(for: chatVM.selectedProvider.rawValue), id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            .disabled(chatVM.isStreaming)

            Button {
                createNewChat()
            } label: {
                Image(systemName: "plus.message")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("New Chat")

            if chatVM.conversationID != nil {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.delete, modifiers: .command)
                .help("Delete Chat")
            }

            Spacer()

            Button {
                appState.startOnboarding()
            } label: {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(appState.profileComplete ? "Update Profile" : "Setup Profile")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showHistory.toggle()
                }
            } label: {
                Image(systemName: "sidebar.trailing")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Toggle Chat History")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if chatVM.messages.isEmpty && chatVM.conversationID != nil {
                            quickPrompts
                        } else if chatVM.messages.isEmpty {
                            emptyState
                        }

                        ForEach(chatVM.messages) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                            actionCards(for: msg)
                        }

                        if let error = chatVM.errorMessage {
                            Text(error)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        }
                        if let err = chatVM.actionFeed.lastError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding()
                }
                .onChange(of: chatVM.messages.count) {
                    if let last = chatVM.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: chatVM.actionFeed.rows.count) {
                    if let last = chatVM.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()
            ChatInput(
                text: $chatVM.inputText,
                isStreaming: chatVM.isStreaming,
                onSend: {
                    if chatVM.conversationID == nil {
                        if let conv = historyVM.createConversation() {
                            chatVM.bind(to: conv)
                        }
                    }
                    chatVM.send()
                },
                onStop: { chatVM.cancelStream() },
                dictationTargetID: "chat.workspace"
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Start a new chat")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Press \(Image(systemName: "command")) N or click \"+\" to begin")
                .font(.callout)
                .foregroundStyle(.tertiary)

            setupProfileButton
        }
        .padding(.top, 60)
    }

    private var quickPrompts: some View {
        VStack(spacing: 8) {
            Text("Ask about your workspace")
                .font(.title2)
                .foregroundStyle(.secondary)
                .padding(.top, 40)

            HStack(spacing: 8) {
                quickPromptButton("What happened today?")
                quickPromptButton("Any decisions?")
                quickPromptButton("Summarize activity")
            }
            .padding(.bottom, 20)

            setupProfileButton
        }
    }

    private var setupProfileButton: some View {
        Button {
            appState.startOnboarding()
        } label: {
            Label(
                appState.profileComplete ? "Update Profile" : "Setup Profile",
                systemImage: "person.crop.circle.badge.questionmark"
            )
        }
        .buttonStyle(.bordered)
        .padding(.top, 8)
    }

    private func quickPromptButton(_ text: String) -> some View {
        Button(text) {
            chatVM.inputText = text
            chatVM.send()
        }
        .buttonStyle(.bordered)
    }

    /// Proposal cards attached to one turn — only a message with a turn id
    /// gets a card slot (a streaming placeholder's turn id lives in memory,
    /// so cards created mid-stream still attach to it).
    @ViewBuilder
    private func actionCards(for msg: ChatMessage) -> some View {
        if let turn = msg.turnID {
            let cards = chatVM.actionFeed.cards(forTurn: turn)
            if cards.filter(\.isPending).count >= 2 {
                Button("Approve all") { Task { await chatVM.actionFeed.approveAllPending(forTurn: turn) } }
                    .font(.caption)
            }
            ForEach(cards) { action in
                AgentActionCardView(
                    action: action,
                    inFlight: chatVM.actionFeed.inFlight.contains(action.id),
                    onApprove: { Task { await chatVM.actionFeed.approve(action.id) } },
                    onReject: { Task { await chatVM.actionFeed.reject(action.id) } },
                    onRetry: { Task { await chatVM.actionFeed.retry(action.id) } }
                )
            }
        }
    }
}

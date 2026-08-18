import SwiftUI
import WatchtowerCore

// MARK: - Chat Section (tab bar + active chat)

/// The target's assistant surface: a chip row of chat tabs on top, the active
/// tab's conversation below. The container owns the chat VMs, so switching tabs
/// never interrupts a turn running in the tab you left.
struct TargetChatSection: View {
    @Bindable var assistant: TargetAssistantViewModel

    @State private var renamingConversationID: Int64?
    @State private var renameText: String = ""
    @State private var showRename = false

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            Divider()

            if let chatVM = assistant.activeChat {
                TargetChatPane(chatVM: chatVM)
            } else {
                noChatState
            }
        }
        .alert("Rename chat", isPresented: $showRename) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let id = renamingConversationID {
                    assistant.rename(id, to: renameText)
                }
            }
        }
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(assistant.conversations) { conversation in
                        chip(conversation)
                    }
                }
                .padding(.vertical, 1)
            }
            Button {
                assistant.newConversation()
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help("Start another chat on this task")
            .accessibilityIdentifier("chat.newTab")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func chip(_ conversation: ChatConversation) -> some View {
        let isActive = conversation.id == assistant.activeConversationID
        return Button {
            assistant.select(conversation.id)
        } label: {
            HStack(spacing: 5) {
                if assistant.isWorking(conversation.id) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .help("This chat is working")
                }
                Text(conversation.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption)
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(maxWidth: 180)
            .background(
                isActive ? Color.accentColor.opacity(0.18) : Color(.controlBackgroundColor),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    isActive ? Color.accentColor.opacity(0.35) : Color(.separatorColor).opacity(0.4),
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.tab.\(conversation.id)")
        .contextMenu {
            Button("Rename…") {
                renamingConversationID = conversation.id
                renameText = conversation.title
                showRename = true
            }
            Button("Close", role: .destructive) {
                assistant.close(conversation.id)
            }
            .disabled(assistant.conversations.count <= 1)
        }
    }

    private var noChatState: some View {
        VStack(spacing: 6) {
            Text(assistant.errorMessage ?? "No chat is open for this task.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Start a chat") { assistant.newConversation() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

// MARK: - One chat

/// One conversation: header, transcript and input. Unchanged by tabs — it is
/// handed the active tab's view model.
struct TargetChatPane: View {
    @Bindable var chatVM: TargetChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            messageList

            Divider()

            ChatInput(
                text: $chatVM.inputText,
                isStreaming: chatVM.isStreaming,
                onSend: { chatVM.send() },
                onStop: { chatVM.cancelStream() },
                placeholder: "Ask the assistant to work on this task…",
                dictationTargetID: "chat.target.\(chatVM.targetID)"
            )

            if let err = chatVM.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
        }
        .background(Color(.controlBackgroundColor).opacity(0.4))
    }

    // MARK: Pending proposals

    /// Rendered in the transcript itself, directly above a message's batch of
    /// proposal cards — the affordance sits where the cards are, not in a
    /// header or a docked bar the eye never visits.
    @ViewBuilder
    private func batchApproveRow(for msg: ChatMessage, cards: [TargetActionCard]) -> some View {
        let pending = cards.filter { $0.state == .pending }.count
        if pending > 1 {
            HStack(spacing: 8) {
                Text("\(pending) proposals")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button { chatVM.approveAll(messageID: msg.id) } label: {
                    Label("Approve all", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Apply every pending proposal in this batch and tell the assistant once")
                .accessibilityIdentifier("chat.approveAll")
                Spacer()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            Text("Assistant")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Picker("Model", selection: $chatVM.selectedModel) {
                ForEach(ChatModel.models(for: chatVM.provider)) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .disabled(chatVM.isStreaming)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chatVM.messages.isEmpty {
                        emptyState
                    }
                    ForEach(chatVM.messages) { msg in
                        chatBubble(msg)
                        let cards = chatVM.actionCards.filter { $0.messageID == msg.id }
                        batchApproveRow(for: msg, cards: cards)
                        ForEach(cards) { card in
                            TargetActionCardView(
                                card: card,
                                onApprove: { kind in chatVM.approve(card, as: kind) },
                                onReject: { chatVM.reject(card) }
                            )
                        }
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: chatVM.messages.count) { scrollToBottom(proxy) }
            .onChange(of: chatVM.messages.last?.text) { scrollToBottom(proxy) }
            .onChange(of: chatVM.actionCards.count) { scrollToBottom(proxy) }
        }
    }

    private let bottomAnchor = "chat-bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor.opacity(0.6))
            Text("Work on this task with AI")
                .font(.subheadline.weight(.medium))
            Text("Ask it to dig through Slack, draft a reply, or update the task — it proposes changes and you approve them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 40)
    }

    @ViewBuilder
    private func chatBubble(_ msg: ChatMessage) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(msg.text)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
            }
        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 9)
                Group {
                    if msg.text.isEmpty && msg.isStreaming {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Thinking…").foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    } else {
                        MarkdownText(text: msg.text)
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color(.separatorColor).opacity(0.25), lineWidth: 0.5)
                )
            }
        case .system:
            Text(msg.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 2)
        }
    }
}

// MARK: - Action Card

struct TargetActionCardView: View {
    let card: TargetActionCard
    /// `kind` is the user's chosen create-kind for checkpoint/sub-task proposals (nil otherwise).
    let onApprove: (TargetActionKind?) -> Void
    let onReject: () -> Void

    /// For add_sub_item / create_child_target the user picks what to actually create.
    @State private var createKind: TargetActionKind

    init(
        card: TargetActionCard,
        onApprove: @escaping (TargetActionKind?) -> Void,
        onReject: @escaping () -> Void
    ) {
        self.card = card
        self.onApprove = onApprove
        self.onReject = onReject
        _createKind = State(initialValue: card.action.type)
    }

    /// add_sub_item and create_child_target are interchangeable — both just need
    /// `text`, so the user can pick either at approve time.
    private var isCreatable: Bool {
        card.action.type == .addSubItem || card.action.type == .createChildTarget
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                Text("Proposed change")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(card.action.cardDescription)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            switch card.state {
            case .pending:
                if isCreatable {
                    Picker("Create as", selection: $createKind) {
                        Text("Checkpoint").tag(TargetActionKind.addSubItem)
                        Text("Sub-task").tag(TargetActionKind.createChildTarget)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                HStack(spacing: 8) {
                    Button { onApprove(isCreatable ? createKind : nil) } label: {
                        Label("Approve", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button(action: onReject) {
                        Label("Reject", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            case .applied(let summary):
                Label(summary, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .rejected:
                Label("Rejected", systemImage: "xmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let err):
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5)
        )
    }

    private var icon: String {
        switch card.action.type {
        case .updateStatus: "flag.fill"
        case .updateNotes: "note.text"
        case .updateProgress: "chart.bar.fill"
        case .addSubItem: "checklist"
        case .createChildTarget: "plus.square.on.square"
        case .linkTarget: "link"
        case .toggleSubItem: "checkmark.circle"
        case .editSubItem: "pencil"
        case .deleteSubItem: "trash"
        case .setSubItemDue: "calendar.badge.clock"
        case .updateDueDate: "calendar"
        case .updatePriority: "exclamationmark.circle"
        case .updateBallOn: "person.circle"
        }
    }
}

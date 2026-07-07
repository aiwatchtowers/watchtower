import SwiftUI
import AppKit

// MARK: - SituationDiscussSection

/// Collapsed-by-default "Discuss with secretary" chat at the bottom of the
/// situation review pane. Inert while collapsed (one cheap message-count read);
/// the chat VM — and any AI call — exists only after the user expands it and
/// acts. Draft replies are copy-only: the app never posts to Slack.
struct SituationDiscussSection: View {
    let situation: Situation
    let memberSignals: [InboxItem]
    let dbManager: DatabaseManager

    @State private var isExpanded = false
    @State private var chatVM: SituationChatViewModel?
    @State private var persistedCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 2)
            header
            if isExpanded, let chatVM {
                SituationDiscussChat(chatVM: chatVM)
                    .padding(.top, 6)
            }
        }
        .onAppear(perform: loadPersistedCount)
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { toggleDiscuss() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Text("Discuss with secretary")
                    .font(.subheadline)
                    .fontWeight(.medium)
                if persistedCount > 0 && !isExpanded {
                    Text("\(persistedCount)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                }
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleDiscuss() {
        if isExpanded {
            chatVM?.cancelStream()
            isExpanded = false
            loadPersistedCount()
            return
        }
        if chatVM == nil {
            chatVM = SituationChatViewModel(
                situation: situation, memberSignals: memberSignals, dbManager: dbManager
            )
        }
        isExpanded = true
    }

    private func loadPersistedCount() {
        let situationID = situation.id
        persistedCount = (try? dbManager.dbPool.read { db in
            try SituationChatViewModel.persistedMessageCount(db, situationID: situationID)
        }) ?? 0
    }
}

// MARK: - Chat body

private struct SituationDiscussChat: View {
    @Bindable var chatVM: SituationChatViewModel

    var body: some View {
        VStack(spacing: 8) {
            messageList
            if let err = chatVM.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button {
                    chatVM.draftReply()
                } label: {
                    Label("Draft reply", systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered)
                .disabled(chatVM.isStreaming)
                .help("Ask the secretary for a ready-to-send reply in your voice")
                Spacer()
            }
            ChatInput(
                text: $chatVM.inputText,
                isStreaming: chatVM.isStreaming,
                onSend: { chatVM.send() },
                onStop: { chatVM.cancelStream() },
                placeholder: "Discuss this situation with the secretary…"
            )
        }
    }

    private var messageList: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            if chatVM.messages.isEmpty {
                Text("Ask anything about this situation, or hit Draft reply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }
            ForEach(chatVM.messages) { msg in
                bubble(msg)
            }
        }
    }

    @ViewBuilder
    private func bubble(_ msg: ChatMessage) -> some View {
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
                VStack(alignment: .trailing, spacing: 4) {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !msg.isStreaming && !msg.text.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(msg.text, forType: .string)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Copy to paste into Slack")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            }
        case .system:
            Text(msg.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

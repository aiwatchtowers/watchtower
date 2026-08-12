import SwiftUI
import AppKit
import WatchtowerCore

// MARK: - SituationDiscussSection

/// Collapsed-by-default "Discuss with secretary" chat at the bottom of the
/// situation review pane's SCROLL content: header + message bubbles only.
/// The input field is docked by the owning `SituationReviewPane` below the
/// scroll (`SituationDiscussInputBar`) — `ChatInput` wraps a nested
/// NSScrollView that collapses inside a SwiftUI ScrollView, so it must live
/// outside it (same placement as TargetChatSection). Expansion state and the
/// chat VM belong to the pane for the same reason; the section stays inert
/// while collapsed (one cheap message-count read). Drafts are copy-only: the
/// app never posts to Slack.
struct SituationDiscussSection: View {
    let situation: Situation
    let memberSignals: [InboxItem]
    let dbManager: DatabaseManager
    @Binding var isExpanded: Bool
    @Binding var chatVM: SituationChatViewModel?

    @State private var persistedCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 2)
            header
            if isExpanded, let chatVM {
                SituationDiscussMessages(chatVM: chatVM)
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

// MARK: - Message list (inside the pane's scroll)

private struct SituationDiscussMessages: View {
    let chatVM: SituationChatViewModel

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            if chatVM.messages.isEmpty {
                Text("Tell me what to reply — I'll draft it in your voice. Or just ask about this situation.")
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

// MARK: - Docked input bar (outside the pane's scroll)

/// The Discuss chat's input row, rendered by `SituationReviewPane` between
/// the scroll content and the action bar while Discuss is expanded.
struct SituationDiscussInputBar: View {
    @Bindable var chatVM: SituationChatViewModel

    var body: some View {
        VStack(spacing: 4) {
            if let err = chatVM.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }
            ChatInput(
                text: $chatVM.inputText,
                isStreaming: chatVM.isStreaming,
                onSend: { chatVM.send() },
                onStop: { chatVM.cancelStream() },
                placeholder: "Tell me what to reply, or ask about this situation…"
            )
        }
    }
}

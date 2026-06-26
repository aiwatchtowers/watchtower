import SwiftUI

// MARK: - Chat Section

struct TargetChatSection: View {
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
                placeholder: "Ask the assistant to work on this task…"
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
                        ForEach(chatVM.actionCards.filter { $0.messageID == msg.id }) { card in
                            TargetActionCardView(
                                card: card,
                                isStreaming: chatVM.isStreaming,
                                onApprove: { chatVM.approve(card) },
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
    /// Disable Approve/Reject while a turn is streaming: a decision taken mid-stream
    /// would apply the write but its follow-up is dropped (sendFollowUp guards on isStreaming).
    let isStreaming: Bool
    let onApprove: () -> Void
    let onReject: () -> Void

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
                HStack(spacing: 8) {
                    Button(action: onApprove) {
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
                .disabled(isStreaming)
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
        }
    }
}
